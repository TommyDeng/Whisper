/// 配对管理器：应用里所有进行中的配对（自己发出的邀请、自己正在加入的邀请）。
///
/// 邀请和加入请求都会存到本地，重启后接着等；批准必须由用户手动点。
library;

import 'dart:async';
import 'dart:convert';

import '../contact/contact_model.dart';
import '../identity/identity.dart';
import '../relay/relay_transport.dart';
import '../storage/pending_invite_store.dart';
import 'invitation_code.dart';
import 'pairing_flow.dart';

/// 等用户批准的一条配对请求。
class IncomingPairRequest {
  const IncomingPairRequest({
    required this.inviteId,
    required this.name,
    required this.safetyCode,
  });

  final String inviteId;

  /// 对方自报的称呼，可能为空。
  final String name;
  final String safetyCode;
}

/// 自己正在加入的一个邀请。
class OutgoingJoin {
  const OutgoingJoin({required this.inviteId, required this.status});

  final String inviteId;
  final PairingStatus status;
}

enum PairingNoticeKind {
  /// 配对完成，联系人已保存。
  contactAdded,

  /// 对方拒绝了我们的加入请求。
  declinedByPeer,

  /// 配对失败。
  failed,
}

/// 一次配对的结果，给界面弹提示用。
class PairingNotice {
  const PairingNotice(this.kind, {required this.asInviter, this.contact, this.failure});

  final PairingNoticeKind kind;
  final bool asInviter;
  final Contact? contact;
  final PairingFailure? failure;
}

/// [PairingManager.join] 没能开始的原因。
enum JoinError { invalidCode, expired, ownInvitation, alreadyJoining }

class PairingManager {
  PairingManager({
    required this.baseUri,
    required this.connector,
    required this.identityManager,
    required this.myName,
    required this.onContact,
  });

  final Uri baseUri;
  final RelayConnector connector;
  final IdentityManager identityManager;

  /// 告诉对方的称呼。
  final Future<String> Function() myName;

  /// 保存新联系人（并开始收发消息）。
  final Future<void> Function(Contact contact) onContact;

  final Map<String, InviterPairing> _inviters = {};
  final Map<String, JoinerPairing> _joiners = {};
  final _changes = StreamController<void>.broadcast();
  final _notices = StreamController<PairingNotice>.broadcast();
  Future<InvitationCode>? _creating;
  bool _disposed = false;
  final Set<PairingFlow> _silenced = {};

  /// 任何一个配对的状态变了（广播流）。
  Stream<void> get changes => _changes.stream;

  /// 配对结果（广播流）。
  Stream<PairingNotice> get notices => _notices.stream;

  /// 恢复上次没走完的邀请。
  Future<void> start() async {
    final identity = await identityManager.identity;
    for (final pending in await PendingInviteStore.loadActive()) {
      final invitation = InvitationCode.decode(pending.code);
      if (invitation == null || invitation.isExpired) {
        await PendingInviteStore.remove(pending.inviteId);
        continue;
      }
      if (pending.role == 'inviter') {
        _startInviter(identity, invitation);
      } else {
        _startJoiner(identity, invitation);
      }
    }
    _notifyChanged();
  }

  /// 当前还能给别人用的邀请码（还没人请求、未过期），没有则为 null。
  InvitationCode? get openInvitation {
    for (final flow in _inviters.values) {
      final open = flow.status == PairingStatus.connecting || flow.status == PairingStatus.waiting;
      if (open && flow.invitation.ttl > 60) return flow.invitation;
    }
    return null;
  }

  /// 该邀请此刻是否已在中继上登记好（对方现在加入能找到它）。
  bool isRegistered(InvitationCode invitation) =>
      _inviters[invitation.inviteId]?.status == PairingStatus.waiting;

  /// 取一个可用的邀请码：有现成的就复用，否则新建并向中继登记。
  Future<InvitationCode> ensureInvitation() {
    final existing = openInvitation;
    if (existing != null) return Future.value(existing);
    return _creating ??= _createInvitation().whenComplete(() => _creating = null);
  }

  Future<InvitationCode> _createInvitation() async {
    final identity = await identityManager.identity;
    final invitation = InvitationCode.create(identity.x25519PublicKey);
    await PendingInviteStore.save(PendingInvite(
      inviteId: invitation.inviteId,
      role: 'inviter',
      code: invitation.encode(),
      expiry: invitation.expiry,
    ));
    _startInviter(identity, invitation);
    _notifyChanged();
    return invitation;
  }

  /// 等用户处理的配对请求。
  List<IncomingPairRequest> get incomingRequests => [
        for (final entry in _inviters.entries)
          if (entry.value.status == PairingStatus.requestReceived)
            IncomingPairRequest(
              inviteId: entry.key,
              name: entry.value.requester?.name ?? '',
              safetyCode: entry.value.safetyCode ?? '',
            ),
      ];

  Future<void> approve(String inviteId) async => _inviters[inviteId]?.approve();

  void reject(String inviteId) => _inviters[inviteId]?.reject();

  /// 自己正在加入、还没有结果的邀请。
  List<OutgoingJoin> get joins => [
        for (final entry in _joiners.entries)
          OutgoingJoin(inviteId: entry.key, status: entry.value.status),
      ];

  /// 用对方的邀请码发起配对。返回 null 表示已经开始，结果通过 [notices] 给出。
  Future<JoinError?> join(String code) async {
    final invitation = InvitationCode.decode(code.trim());
    if (invitation == null) return JoinError.invalidCode;
    if (invitation.isExpired) return JoinError.expired;
    if (_joiners.containsKey(invitation.inviteId)) return JoinError.alreadyJoining;
    final identity = await identityManager.identity;
    if (base64Url.encode(invitation.publicKey) == identity.x25519PublicKeyBase64) {
      return JoinError.ownInvitation;
    }
    await PendingInviteStore.save(PendingInvite(
      inviteId: invitation.inviteId,
      role: 'joiner',
      code: invitation.encode(),
      expiry: invitation.expiry,
    ));
    _startJoiner(identity, invitation);
    _notifyChanged();
    return null;
  }

  /// 放弃一个正在加入的邀请。
  Future<void> cancelJoin(String inviteId) async => _joiners[inviteId]?.cancel();

  void _startInviter(IdentityKeyPair identity, InvitationCode invitation) {
    final inviteId = invitation.inviteId;
    if (_disposed || _inviters.containsKey(inviteId)) return;
    Contact? saved;
    final flow = InviterPairing(
      baseUri: baseUri,
      connector: connector,
      identity: identity,
      invitation: invitation,
      myName: myName,
      onPaired: (peer) async {
        saved = _contactFor(identity, peer);
        await onContact(saved!);
      },
    );
    _inviters[inviteId] = flow;
    _track(flow, inviteId, asInviter: true, contact: () => saved, flows: _inviters);
  }

  void _startJoiner(IdentityKeyPair identity, InvitationCode invitation) {
    final inviteId = invitation.inviteId;
    if (_disposed || _joiners.containsKey(inviteId)) return;
    Contact? saved;
    final flow = JoinerPairing(
      baseUri: baseUri,
      connector: connector,
      identity: identity,
      invitation: invitation,
      myName: myName,
      onPaired: (peer) async {
        saved = _contactFor(identity, peer);
        await onContact(saved!);
      },
    );
    _joiners[inviteId] = flow;
    _track(flow, inviteId, asInviter: false, contact: () => saved, flows: _joiners);
  }

  void _track(
    PairingFlow flow,
    String inviteId, {
    required bool asInviter,
    required Contact? Function() contact,
    required Map<String, PairingFlow> flows,
  }) {
    flow.statuses.listen((_) => _notifyChanged());
    unawaited(flow.finished.then((status) async {
      flows.remove(inviteId);
      final failure = flow.failure;
      // 应用退出、或被另一个实例顶掉时保留记录，下次启动接着等；其它结局都是终局
      final silenced = _silenced.remove(flow);
      final keep = _disposed || silenced || (failure == PairingFailure.replaced);
      if (!keep) {
        try {
          await PendingInviteStore.remove(inviteId);
        } catch (_) {
          // 删不掉也没关系：过期后会被清理
        }
      }
      if (_disposed || silenced) return;
      switch (status) {
        case PairingStatus.done:
          _notices.add(PairingNotice(
            PairingNoticeKind.contactAdded,
            asInviter: asInviter,
            contact: contact(),
          ));
        case PairingStatus.rejected:
          // 邀请人自己点的拒绝不需要再提示
          if (!asInviter) {
            _notices.add(const PairingNotice(PairingNoticeKind.declinedByPeer, asInviter: false));
          }
        default:
          if (failure != PairingFailure.cancelled) {
            _notices.add(PairingNotice(
              PairingNoticeKind.failed,
              asInviter: asInviter,
              failure: failure,
            ));
          }
      }
      _notifyChanged();
    }));
    flow.start();
  }

  Contact _contactFor(IdentityKeyPair identity, PairedPeer peer) {
    final publicKey = base64Url.encode(peer.profile.x25519PublicKey);
    final name = peer.profile.name.trim();
    final now = DateTime.now().millisecondsSinceEpoch;
    return Contact(
      deviceId: publicKey,
      name: name.isEmpty ? '新联系人' : name,
      x25519PublicKeyBase64: publicKey,
      ed25519PublicKeyBase64: base64Url.encode(peer.profile.ed25519PublicKey),
      safetyCode: SafetyCode.compute(identity.x25519PublicKeyBase64, publicKey),
      isVerified: false,
      createdAt: now,
      lastMessageTime: now,
      sessionId: peer.sessionId,
      peerRole: peer.myRole,
    );
  }

  void _notifyChanged() {
    if (!_disposed) _changes.add(null);
  }

  /// 清空全部数据时调用：放弃所有进行中的配对，不发任何提示。
  /// 本地保存的邀请由调用方连同数据库一起删除。
  Future<void> reset() async {
    final flows = <PairingFlow>[..._inviters.values, ..._joiners.values];
    _silenced.addAll(flows);
    _inviters.clear();
    _joiners.clear();
    await Future.wait(flows.map((flow) => flow.cancel()));
    _notifyChanged();
  }

  /// 断开所有配对连接。本地保存的邀请保留，下次 [start] 时恢复。
  Future<void> dispose() async {
    _disposed = true;
    final flows = [..._inviters.values.map((f) => f.cancel()), ..._joiners.values.map((f) => f.cancel())];
    await Future.wait(flows);
    await _changes.close();
    await _notices.close();
  }
}

/// 把失败原因翻译成给用户看的话。
String describePairingFailure(PairingFailure? failure, {required bool asInviter}) {
  switch (failure) {
    case PairingFailure.notFound:
      return '找不到这个邀请。请确认对方的应用开着，并且邀请码没有抄错。';
    case PairingFailure.expired:
      return '邀请已过期。';
    case PairingFailure.used:
      return asInviter ? '这个邀请已经失效，请重新生成。' : '这个邀请已经被使用过了。';
    case PairingFailure.forbidden:
      return '这个邀请不属于当前身份。';
    case PairingFailure.replaced:
      return '同一个身份在别处也打开了这个邀请。';
    case PairingFailure.invalidRequest:
      return '收到的配对请求无法识别，已自动拒绝。';
    case PairingFailure.invalidResponse:
      return '对方的应答无法验证，配对已中止。';
    case PairingFailure.cancelled:
      return '已取消。';
    case null:
      return '配对失败。';
  }
}
