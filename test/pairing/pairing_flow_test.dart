import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/identity/identity_store.dart';
import 'package:whisper/identity/safety_code.dart';
import 'package:whisper/pairing/invitation_code.dart';
import 'package:whisper/pairing/pairing_flow.dart';
import 'package:whisper/pairing/pairing_payload.dart';
import 'package:whisper/relay/relay_transport.dart';

import '../relay/fake_relay.dart';

final _base = Uri.parse('wss://relay.test');
const _fast = [Duration(milliseconds: 1)];

/// 等条件成立（真实时钟；加解密是异步的，不能用 fake_async）。
Future<void> _until(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('超时：${reason ?? '条件未成立'}');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

PairProfile _profile(IdentityKeyPair identity, String name) => PairProfile(
      x25519PublicKey: identity.x25519PublicKey,
      ed25519PublicKey: identity.ed25519PublicKey,
      name: name,
    );

void main() {
  late IdentityKeyPair alice; // 邀请人
  late IdentityKeyPair bob; // 加入者
  late InvitationCode invitation;
  late FakeRelay relay;
  RelayRejected? rejection;
  late List<PairedPeer> paired;

  Future<RelayConnection> connect(Uri uri) {
    final rejected = rejection;
    if (rejected != null) {
      relay.attempts.add(uri);
      throw rejected;
    }
    return relay.connect(uri);
  }

  setUp(() async {
    alice = await generateIdentityKeyPair();
    bob = await generateIdentityKeyPair();
    invitation = InvitationCode.create(alice.x25519PublicKey);
    relay = FakeRelay();
    rejection = null;
    paired = [];
  });

  group('deriveInviteKey', () {
    test('稳定、符合中继的格式，角色或 token 不同则不同', () {
      String key(String role, Uint8List token) =>
          deriveInviteKey(privateKey: alice.x25519PrivateKey, role: role, token: token);
      final other = Uint8List.fromList(List.filled(16, 7));

      expect(key('inviter', invitation.token), key('inviter', invitation.token));
      expect(key('inviter', invitation.token), matches(RegExp(r'^[A-Za-z0-9_-]{16,64}$')));
      expect(key('inviter', invitation.token), isNot(key('joiner', invitation.token)));
      expect(key('inviter', invitation.token), isNot(key('inviter', other)));
    });
  });

  group('邀请人', () {
    InviterPairing start() {
      final flow = InviterPairing(
        baseUri: _base,
        connector: connect,
        identity: alice,
        invitation: invitation,
        myName: () async => '  爱丽丝 ',
        onPaired: (peer) async => paired.add(peer),
        backoff: _fast,
      )..start();
      addTearDown(flow.cancel);
      return flow;
    }

    Future<String> request({String name = '鲍勃'}) => PairingPayload.sealRequest(
          inviterPublicKey: alice.x25519PublicKey,
          token: invitation.token,
          joiner: _profile(bob, name),
        );

    Future<InviterPairing> startWithRequest() async {
      final flow = start();
      await _until(() => relay.connections.isNotEmpty);
      relay.last.push({'type': 'welcome', 'role': 'inviter', 'state': 'open'});
      relay.last.push({'type': 'pair-request', 'payload': await request()});
      await _until(() => flow.status == PairingStatus.requestReceived);
      return flow;
    }

    test('连接地址带角色、key 和过期时间；邀请 ID 不带填充', () async {
      final flow = start();
      await _until(() => relay.attempts.isNotEmpty);
      final uri = relay.attempts.single;
      expect(uri.host, 'relay.test');
      expect(uri.path, '/invite/${invitation.inviteId}');
      expect(invitation.inviteId, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      expect(uri.queryParameters['role'], 'inviter');
      expect(uri.queryParameters['expires'], '${invitation.expiry}');
      expect(
        uri.queryParameters['key'],
        deriveInviteKey(privateKey: alice.x25519PrivateKey, role: 'inviter', token: invitation.token),
      );

      expect(flow.status, PairingStatus.connecting);
      relay.last.push({'type': 'welcome', 'role': 'inviter', 'state': 'open'});
      await _until(() => flow.status == PairingStatus.waiting);
    });

    test('收到请求后显示对方资料和安全码，批准后保存联系人', () async {
      final flow = await startWithRequest();
      expect(flow.requester!.name, '鲍勃');
      expect(flow.requester!.x25519PublicKey, bob.x25519PublicKey);
      expect(
        flow.safetyCode,
        SafetyCode.compute(alice.x25519PublicKeyBase64, bob.x25519PublicKeyBase64),
      );
      expect(relay.last.sentOfType('pair-response'), isEmpty, reason: '没批准前不能自动应答');

      await flow.approve();
      final response = relay.last.sentOfType('pair-response').single;
      expect(response['accepted'], isTrue);
      final acceptance = await PairingPayload.openResponse(
        payload: response['payload'] as String,
        joinerPrivateKey: bob.x25519PrivateKey,
        inviterPublicKey: alice.x25519PublicKey,
        token: invitation.token,
      );
      expect(acceptance.inviter.name, '爱丽丝');
      expect(flow.status, PairingStatus.responding);
      expect(paired, isEmpty, reason: '中继确认收下应答之前不保存');

      relay.last.push({'type': 'stored'});
      expect(await flow.finished, PairingStatus.done);
      expect(paired.single.sessionId, acceptance.sessionId);
      expect(paired.single.myRole, 'a');
      expect(paired.single.profile.ed25519PublicKey, bob.ed25519PublicKey);
      expect(relay.last.closedByClient, isTrue);
    });

    test('拒绝：应答不带内容，不保存联系人', () async {
      final flow = await startWithRequest();
      flow.reject();
      final response = relay.last.sentOfType('pair-response').single;
      expect(response['accepted'], isFalse);
      expect(response['payload'], '');

      relay.last.push({'type': 'stored'});
      expect(await flow.finished, PairingStatus.rejected);
      expect(paired, isEmpty);
    });

    test('解不开的请求自动拒绝，并以 invalidRequest 结束', () async {
      final flow = start();
      await _until(() => relay.connections.isNotEmpty);
      relay.last.push({'type': 'welcome', 'role': 'inviter', 'state': 'open'});
      relay.last.push({'type': 'pair-request', 'payload': 'not-a-payload'});
      await _until(() => relay.last.sentOfType('pair-response').isNotEmpty);
      expect(relay.last.sentOfType('pair-response').single['accepted'], isFalse);

      relay.last.push({'type': 'stored'});
      expect(await flow.finished, PairingStatus.failed);
      expect(flow.failure, PairingFailure.invalidRequest);
      expect(paired, isEmpty);
    });

    test('应答没被确认就断线：重连后补发同一份应答，不再让用户决定一次', () async {
      final flow = await startWithRequest();
      await flow.approve();
      final first = relay.last.sentOfType('pair-response').single;
      relay.last.drop();

      await _until(() => relay.connections.length == 2);
      relay.last.push({'type': 'welcome', 'role': 'inviter', 'state': 'requested'});
      relay.last.push({'type': 'pair-request', 'payload': await request()});
      await _until(() => relay.last.sentOfType('pair-response').isNotEmpty);
      expect(relay.last.sentOfType('pair-response').single, first);
      expect(flow.status, PairingStatus.responding);

      relay.last.push({'type': 'stored'});
      expect(await flow.finished, PairingStatus.done);
      expect(paired, hasLength(1));
    });

    test('应答发出后重连被告知邀请已用完：按成功处理', () async {
      final flow = await startWithRequest();
      await flow.approve();
      rejection = const RelayRejected(410, 'invite-used');
      relay.last.drop();
      expect(await flow.finished, PairingStatus.done);
      expect(paired, hasLength(1));
    });

    test('等待期间断线会重连，重连中状态回到 connecting', () async {
      final flow = start();
      await _until(() => relay.connections.isNotEmpty);
      relay.last.push({'type': 'welcome', 'role': 'inviter', 'state': 'open'});
      await _until(() => flow.status == PairingStatus.waiting);

      relay.refuse = true;
      relay.last.drop();
      await _until(() => relay.attempts.length >= 3);
      expect(flow.status, PairingStatus.connecting);
      relay.refuse = false;
      await _until(() => relay.connections.length == 2);
      relay.last.push({'type': 'welcome', 'role': 'inviter', 'state': 'open'});
      await _until(() => flow.status == PairingStatus.waiting);
    });

    test('中继拒绝连接：按错误码结束，不重试', () async {
      rejection = const RelayRejected(403, 'forbidden');
      final flow = start();
      expect(await flow.finished, PairingStatus.failed);
      expect(flow.failure, PairingFailure.forbidden);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(relay.attempts, hasLength(1));
    });

    test('中继返回未知错误（如 500）时重试', () async {
      rejection = const RelayRejected(500);
      final flow = start();
      await _until(() => relay.attempts.length >= 3);
      expect(flow.isFinished, isFalse);
    });

    test('邀请过期被中继关闭（4002）', () async {
      final flow = start();
      await _until(() => relay.connections.isNotEmpty);
      relay.last.push({'type': 'welcome', 'role': 'inviter', 'state': 'open'});
      relay.last.drop(4002);
      expect(await flow.finished, PairingStatus.failed);
      expect(flow.failure, PairingFailure.expired);
    });

    test('本地已过期的邀请不去连接', () async {
      invitation = InvitationCode(
        publicKey: alice.x25519PublicKey,
        token: invitation.token,
        expiry: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 1,
      );
      final flow = start();
      expect(await flow.finished, PairingStatus.failed);
      expect(flow.failure, PairingFailure.expired);
      expect(relay.attempts, isEmpty);
    });

    test('取消后断开连接', () async {
      final flow = start();
      await _until(() => relay.connections.isNotEmpty);
      await flow.cancel();
      expect(flow.failure, PairingFailure.cancelled);
      expect(relay.last.closedByClient, isTrue);
    });
  });

  group('加入者', () {
    late List<String> order;

    JoinerPairing start() {
      order = [];
      final flow = JoinerPairing(
        baseUri: _base,
        connector: connect,
        identity: bob,
        invitation: invitation,
        myName: () async => '鲍勃',
        onPaired: (peer) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          paired.add(peer);
          order.add('saved');
        },
        backoff: _fast,
      )..start();
      addTearDown(flow.cancel);
      return flow;
    }

    Future<String> response(IdentityKeyPair inviter, String sessionId) => PairingPayload.sealResponse(
          inviterPrivateKey: inviter.x25519PrivateKey,
          joinerPublicKey: bob.x25519PublicKey,
          token: invitation.token,
          sessionId: sessionId,
          inviter: _profile(inviter, '爱丽丝'),
        );

    test('发出邀请人能解开的请求，批准后先保存联系人再发 pair-done', () async {
      final flow = start();
      await _until(() => relay.connections.isNotEmpty);
      final uri = relay.attempts.single;
      expect(uri.path, '/invite/${invitation.inviteId}');
      expect(uri.queryParameters['role'], 'joiner');
      expect(uri.queryParameters.containsKey('expires'), isFalse);

      final connection = relay.last;
      connection.push({'type': 'welcome', 'role': 'joiner', 'state': 'open'});
      await _until(() => connection.sentOfType('pair-request').isNotEmpty);
      final profile = await PairingPayload.openRequest(
        payload: connection.sentOfType('pair-request').single['payload'] as String,
        inviterPrivateKey: alice.x25519PrivateKey,
        token: invitation.token,
      );
      expect(profile.name, '鲍勃');
      expect(profile.x25519PublicKey, bob.x25519PublicKey);
      expect(flow.status, PairingStatus.connecting);

      connection.push({'type': 'stored'});
      await _until(() => flow.status == PairingStatus.waiting);

      final sessionId = PairingPayload.newSessionId();
      connection.push({
        'type': 'pair-response',
        'accepted': true,
        'payload': await response(alice, sessionId),
      });
      final sub = flow.statuses.listen((status) {
        if (status == PairingStatus.done) order.add('done');
      });
      addTearDown(sub.cancel);
      expect(await flow.finished, PairingStatus.done);
      expect(paired.single.sessionId, sessionId);
      expect(paired.single.myRole, 'b');
      expect(paired.single.profile.name, '爱丽丝');
      expect(connection.sentOfType('pair-done'), hasLength(1));
      expect(order.first, 'saved');
    });

    test('被拒绝：确认收到后结束，不保存联系人', () async {
      final flow = start();
      await _until(() => relay.connections.isNotEmpty);
      final connection = relay.last;
      connection.push({'type': 'welcome', 'role': 'joiner', 'state': 'responded'});
      connection.push({'type': 'pair-response', 'accepted': false, 'payload': ''});
      expect(await flow.finished, PairingStatus.rejected);
      expect(connection.sentOfType('pair-done'), hasLength(1));
      expect(connection.sentOfType('pair-request'), isEmpty);
      expect(paired, isEmpty);
    });

    test('应答不是邀请码里那把公钥的主人发的：拒收', () async {
      final mallory = await generateIdentityKeyPair();
      final flow = start();
      await _until(() => relay.connections.isNotEmpty);
      relay.last.push({'type': 'welcome', 'role': 'joiner', 'state': 'requested'});
      relay.last.push({
        'type': 'pair-response',
        'accepted': true,
        'payload': await response(mallory, PairingPayload.newSessionId()),
      });
      expect(await flow.finished, PairingStatus.failed);
      expect(flow.failure, PairingFailure.invalidResponse);
      expect(paired, isEmpty);
    });

    test('重连时请求已在中继上：不重复发送', () async {
      final flow = start();
      await _until(() => relay.connections.isNotEmpty);
      relay.last.push({'type': 'welcome', 'role': 'joiner', 'state': 'open'});
      await _until(() => relay.last.sentOfType('pair-request').isNotEmpty);
      final first = relay.last.sentOfType('pair-request').single;
      relay.last.drop();

      // 第一次的请求没被确认：重连后状态仍是 open，补发同一份
      await _until(() => relay.connections.length == 2);
      relay.last.push({'type': 'welcome', 'role': 'joiner', 'state': 'open'});
      await _until(() => relay.last.sentOfType('pair-request').isNotEmpty);
      expect(relay.last.sentOfType('pair-request').single, first);
      relay.last.push({'type': 'stored'});
      await _until(() => flow.status == PairingStatus.waiting);
      relay.last.drop();

      await _until(() => relay.connections.length == 3);
      expect(flow.status, PairingStatus.connecting);
      relay.last.push({'type': 'welcome', 'role': 'joiner', 'state': 'requested'});
      await _until(() => flow.status == PairingStatus.waiting);
      expect(relay.last.sentOfType('pair-request'), isEmpty);
    });

    test('邀请不存在、已过期、已被使用', () async {
      Future<PairingFailure?> failureFor(RelayRejected rejected) async {
        rejection = rejected;
        final flow = start();
        expect(await flow.finished, PairingStatus.failed);
        return flow.failure;
      }

      expect(await failureFor(const RelayRejected(404, 'invite-not-found')), PairingFailure.notFound);
      expect(await failureFor(const RelayRejected(410, 'invite-expired')), PairingFailure.expired);
      expect(await failureFor(const RelayRejected(410, 'invite-used')), PairingFailure.used);
    });

    test('别人抢先用了邀请：收到 invite-used 后结束', () async {
      final flow = start();
      await _until(() => relay.connections.isNotEmpty);
      relay.last.push({'type': 'welcome', 'role': 'joiner', 'state': 'open'});
      relay.last.push({'type': 'error', 'error': 'invite-used'});
      expect(await flow.finished, PairingStatus.failed);
      expect(flow.failure, PairingFailure.used);
    });

    test('畸形帧不影响流程', () async {
      final flow = start();
      await _until(() => relay.connections.isNotEmpty);
      relay.last.pushRaw('not json');
      relay.last.pushRaw(jsonEncode([1, 2]));
      relay.last.push({'type': 'pair-response', 'accepted': 'yes', 'payload': 1});
      relay.last.push({'type': 'welcome', 'role': 'joiner', 'state': 'requested'});
      await _until(() => flow.status == PairingStatus.waiting);
    });
  });
}
