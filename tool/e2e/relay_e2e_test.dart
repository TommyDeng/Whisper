// 对着真实中继（本地 `wrangler dev` 或线上）走一遍：配对 → 互发消息 → 离线消息。
//
//   cd worker && npx wrangler dev --ip 127.0.0.1 --port 8787
//   WHISPER_E2E_RELAY=ws://127.0.0.1:8787 flutter test tool/e2e/relay_e2e_test.dart
//
// 不在 test/ 下，所以不参与门禁和 CI。
import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/identity/identity_store.dart';
import 'package:whisper/messaging/message_codec.dart';
import 'package:whisper/pairing/invitation_code.dart';
import 'package:whisper/pairing/pairing_flow.dart';
import 'package:whisper/relay/session_client.dart';
import 'package:whisper/relay/ws_connector.dart';

Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _Side {
  _Side(this.identity, this.peer);

  final IdentityKeyPair identity;
  final PairedPeer peer;
  final List<String> received = [];
  final List<String> stored = [];
  final List<String> delivered = [];
  late final SecretKey key;
  late SessionClient client;

  Future<void> init() async {
    key = await MessageCodec.deriveKey(
      myPrivateKey: identity.x25519PrivateKey,
      peerPublicKey: peer.profile.x25519PublicKey,
      sessionId: peer.sessionId,
    );
  }

  void connect(Uri base) {
    client = SessionClient(
      baseUri: base,
      sessionId: peer.sessionId,
      peer: peer.myRole,
      connector: connectWebSocket,
      onMessage: (message) async {
        final content = await MessageCodec.open(
          key: key,
          sessionId: peer.sessionId,
          senderRole: peer.myRole == 'a' ? 'b' : 'a',
          messageId: message.id,
          payload: message.payload,
        );
        received.add(content.body);
      },
    );
    client.stored.listen(stored.add);
    client.delivered.listen(delivered.add);
    client.start();
  }

  Future<String> send(String text) async {
    final id = MessageCodec.newMessageId();
    client.send(
      id,
      await MessageCodec.seal(
        key: key,
        sessionId: peer.sessionId,
        senderRole: peer.myRole,
        messageId: id,
        content: ChatContent.text(text, sentAt: DateTime.now().millisecondsSinceEpoch),
      ),
    );
    return id;
  }
}

void main() {
  final relay = Platform.environment['WHISPER_E2E_RELAY'];

  test('配对、互发消息、离线消息', () async {
    final base = Uri.parse(relay!);
    final alice = await generateIdentityKeyPair();
    final bob = await generateIdentityKeyPair();
    final invitation = InvitationCode.decode(InvitationCode.create(alice.x25519PublicKey).encode())!;

    PairedPeer? alicePeer, bobPeer;
    final inviter = InviterPairing(
      baseUri: base,
      connector: connectWebSocket,
      identity: alice,
      invitation: invitation,
      onPaired: (peer) async => alicePeer = peer,
      myName: () async => 'Alice',
    );
    inviter.start();
    await _until(() => inviter.status == PairingStatus.waiting, '邀请登记');

    final joiner = JoinerPairing(
      baseUri: base,
      connector: connectWebSocket,
      identity: bob,
      invitation: invitation,
      onPaired: (peer) async => bobPeer = peer,
      myName: () async => 'Bob',
    );
    joiner.start();
    await _until(() => inviter.status == PairingStatus.requestReceived, '邀请人收到请求');
    expect(inviter.requester!.name, 'Bob');
    expect(inviter.safetyCode, isNotEmpty);
    await inviter.approve();
    await Future.wait([inviter.finished, joiner.finished]).timeout(const Duration(seconds: 15));
    expect(inviter.status, PairingStatus.done);
    expect(joiner.status, PairingStatus.done);
    expect(alicePeer!.sessionId, bobPeer!.sessionId);
    expect(alicePeer!.myRole, 'a');
    expect(bobPeer!.myRole, 'b');
    expect(bobPeer!.profile.name, 'Alice');
    expect(alicePeer!.profile.x25519PublicKey, bob.x25519PublicKey);

    // 邀请只能用一次
    final late_ = JoinerPairing(
      baseUri: base,
      connector: connectWebSocket,
      identity: await generateIdentityKeyPair(),
      invitation: invitation,
      onPaired: (_) async {},
      myName: () async => 'Mallory',
    );
    late_.start();
    await late_.finished.timeout(const Duration(seconds: 15));
    expect(late_.status, PairingStatus.failed);
    expect(late_.failure, PairingFailure.used);

    final a = _Side(alice, alicePeer!);
    final b = _Side(bob, bobPeer!);
    await a.init();
    await b.init();
    a.connect(base);
    b.connect(base);
    await _until(() => a.client.peerOnline && b.client.peerOnline, '双方在线');

    final id1 = await a.send('你好 Bob');
    await _until(() => b.received.contains('你好 Bob'), 'Bob 收到');
    await _until(() => a.stored.contains(id1) && a.delivered.contains(id1), 'Alice 得到 stored 和 delivered');
    await b.send('你好 Alice');
    await _until(() => a.received.contains('你好 Alice'), 'Alice 收到');

    // Bob 离线期间的消息，上线后补投
    await b.client.stop();
    await _until(() => !a.client.peerOnline, 'Alice 看到 Bob 离线');
    final id2 = await a.send('离线消息 1');
    final id3 = await a.send('离线消息 2');
    await _until(() => a.stored.contains(id2) && a.stored.contains(id3), '中继收下离线消息');
    expect(a.delivered, isNot(contains(id2)));
    b.connect(base);
    await _until(() => b.received.length == 3, 'Bob 上线后收到离线消息');
    expect(b.received, ['你好 Bob', '离线消息 1', '离线消息 2']);
    await _until(() => a.delivered.contains(id2) && a.delivered.contains(id3), 'Alice 得到送达回执');

    await a.client.stop();
    await b.client.stop();
  }, skip: relay == null ? '未设置 WHISPER_E2E_RELAY' : false, timeout: const Timeout(Duration(minutes: 2)));
}
