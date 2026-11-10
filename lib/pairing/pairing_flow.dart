/// 配对流程（客户端一侧）：通过中继的 `/invite/<id>` 交换加密的配对请求和应答。
///
/// 中继协议见 docs/relay-protocol.md 第二节，载荷格式见 docs/pairing-payload.md。
/// 这里只管连接、重连和状态推进；界面和落库由调用方通过回调完成。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../identity/identity_store.dart';
import '../identity/safety_code.dart';
import '../relay/relay_transport.dart';
import 'invitation_code.dart';
import 'pairing_payload.dart';

/// 配对进行到哪一步。
enum PairingStatus {
  /// 正在连接中继（或断线后重连）。
  connecting,

  /// 邀请人：等对方加入。加入者：请求已送达中继，等邀请人批准。
  waiting,

  /// 邀请人：收到请求，等用户批准或拒绝。
  requestReceived,

  /// 邀请人：已做出决定，正在把应答交给中继。
  responding,

  /// 配对完成，联系人已保存。
  done,

  /// 邀请人拒绝了请求。
  rejected,

  /// 失败，原因见 failure。
  failed,
}

enum PairingFailure {
  /// 中继上没有这个邀请（邀请人还没上线登记，或码不对）。
  notFound,
  expired,

  /// 邀请已被别人使用或已经用完。
  used,
  forbidden,

  /// 同一身份在别处又连了一次。
  replaced,

  /// 对方发来的请求解不开。
  invalidRequest,

  /// 邀请人的应答解不开，或公钥与邀请码不符。
  invalidResponse,
  cancelled,
}

/// 配对成功后得到的对方信息。
class PairedPeer {
  const PairedPeer({required this.sessionId, required this.myRole, required this.profile});

  final String sessionId;

  /// 自己在会话里的身份：邀请人 `a`，加入者 `b`。
  final String myRole;
  final PairProfile profile;
}

/// 保存联系人。它正常返回后流程才继续（加入者此后才发 `pair-done`）。
typedef PairedHandler = Future<void> Function(PairedPeer peer);

const List<Duration> _defaultBackoff = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 15),
  Duration(seconds: 30),
];

/// 连接邀请时用的 key：由身份私钥和 token 算出，重启后不变，
/// 这样重连时中继仍把我们当作同一方。不同角色、不同邀请得到的 key 不同。
String deriveInviteKey({
  required Uint8List privateKey,
  required String role,
  required Uint8List token,
}) {
  final mac = Hmac(sha256, privateKey).convert([
    ...utf8.encode('whisper/invite-key/v1/$role/'),
    ...token,
  ]);
  return base64Url.encode(mac.bytes).replaceAll('=', '');
}

PairingFailure? _failureForRejection(RelayRejected rejection) {
  switch (rejection.error) {
    case 'invite-not-found':
      return PairingFailure.notFound;
    case 'invite-expired':
    case 'bad-expiry':
      return PairingFailure.expired;
    case 'invite-used':
      return PairingFailure.used;
    case 'forbidden':
      return PairingFailure.forbidden;
  }
  return null; // 其它情况（5xx、限流等）当作暂时故障，重试
}

PairingFailure? _failureForCloseCode(int? code) {
  switch (code) {
    case 4001:
      return PairingFailure.replaced;
    case 4002:
      return PairingFailure.expired;
    case 4003:
      return PairingFailure.used;
  }
  return null;
}

/// 到 `/invite/<id>` 的连接：自动重连、心跳。
class _InviteChannel {
  _InviteChannel({
    required this.uri,
    required this.connector,
    required this.backoff,
    required this.pingInterval,
    required this.onFrame,
    required this.onRejected,
    required this.onClosed,
  });

  final Uri uri;
  final RelayConnector connector;
  final List<Duration> backoff;
  final Duration pingInterval;
  final void Function(Map<String, dynamic> frame) onFrame;

  /// 升级被拒绝。返回 true 表示稍后重试。
  final bool Function(RelayRejected rejection) onRejected;

  /// 连接断开。返回 true 表示重连。
  final bool Function(int? closeCode) onClosed;

  RelayConnection? _connection;
  StreamSubscription<String>? _subscription;
  Timer? _retryTimer;
  Timer? _pingTimer;
  bool _awaitingPong = false;
  bool _stopped = false;
  int _failures = 0;
  int _generation = 0;

  void start() => unawaited(_connect());

  Future<void> _connect() async {
    if (_stopped) return;
    final generation = ++_generation;
    final RelayConnection connection;
    try {
      connection = await connector(uri);
    } on RelayRejected catch (rejection) {
      if (_stopped || generation != _generation) return;
      if (onRejected(rejection)) _scheduleRetry();
      return;
    } catch (_) {
      if (_stopped || generation != _generation) return;
      _scheduleRetry();
      return;
    }
    if (_stopped || generation != _generation) {
      unawaited(connection.close());
      return;
    }

    _connection = connection;
    _awaitingPong = false;
    _subscription = connection.frames.listen(
      (text) {
        if (_stopped || generation != _generation) return;
        final Map<String, dynamic> frame;
        try {
          final decoded = jsonDecode(text);
          if (decoded is! Map<String, dynamic>) return;
          frame = decoded;
        } catch (_) {
          return;
        }
        _awaitingPong = false;
        if (frame['type'] == 'welcome') _failures = 0;
        if (frame['type'] == 'pong') return;
        onFrame(frame);
      },
      onDone: () {
        if (_stopped || generation != _generation) return;
        _pingTimer?.cancel();
        _connection = null;
        if (onClosed(connection.closeCode)) _scheduleRetry();
      },
    );
    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (_awaitingPong) {
        // 上一个 ping 没有任何回音：当作连接已死，关掉重连
        unawaited(connection.close());
        return;
      }
      _awaitingPong = send({'type': 'ping'});
    });
  }

  void _scheduleRetry() {
    if (_stopped) return;
    _failures++;
    final index = _failures - 1 < backoff.length ? _failures - 1 : backoff.length - 1;
    _retryTimer?.cancel();
    _retryTimer = Timer(backoff[index], () => unawaited(_connect()));
  }

  /// 发一帧。没连上或发送失败时返回 false。
  bool send(Map<String, dynamic> frame) {
    final connection = _connection;
    if (connection == null) return false;
    try {
      connection.send(jsonEncode(frame));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _retryTimer?.cancel();
    _pingTimer?.cancel();
    final connection = _connection;
    _connection = null;
    final subscription = _subscription;
    _subscription = null;
    if (connection != null) unawaited(connection.close());
    await subscription?.cancel();
  }
}

/// 一次配对。两种角色共用的状态与收尾逻辑在这里，具体步骤见
/// [InviterPairing] 和 [JoinerPairing]。
abstract class PairingFlow {
  PairingFlow({
    required Uri baseUri,
    required RelayConnector connector,
    required this.identity,
    required this.invitation,
    required this.onPaired,
    required String role,
    required List<Duration> backoff,
    required Duration pingInterval,
    bool sendExpiry = false,
  }) {
    _channel = _InviteChannel(
      uri: baseUri.replace(
        path: '/invite/${invitation.inviteId}',
        queryParameters: {
          'role': role,
          'key': deriveInviteKey(
            privateKey: identity.x25519PrivateKey,
            role: role,
            token: invitation.token,
          ),
          if (sendExpiry) 'expires': '${invitation.expiry}',
        },
      ),
      connector: connector,
      backoff: backoff,
      pingInterval: pingInterval,
      onFrame: (frame) {
        if (!isFinished) _onFrame(frame);
      },
      onRejected: (rejection) {
        if (isFinished) return false;
        final failure = _failureForRejection(rejection);
        if (failure == null) return true;
        _onTerminal(failure);
        return false;
      },
      onClosed: (code) {
        if (isFinished) return false;
        final failure = _failureForCloseCode(code);
        if (failure == null) {
          _setStatus(_statusWhileReconnecting());
          return true;
        }
        _onTerminal(failure);
        return false;
      },
    );
  }

  final IdentityKeyPair identity;
  final InvitationCode invitation;
  final PairedHandler onPaired;

  late final _InviteChannel _channel;
  final _statusController = StreamController<PairingStatus>.broadcast();
  final _finished = Completer<PairingStatus>();
  PairingStatus _status = PairingStatus.connecting;
  PairingFailure? _failure;
  Timer? _expiryTimer;
  bool _started = false;

  PairingStatus get status => _status;

  /// 状态变化（广播流，结束后关闭）。
  Stream<PairingStatus> get statuses => _statusController.stream;

  /// 失败原因；只有 [status] 为 failed 时有值。
  PairingFailure? get failure => _failure;

  bool get isFinished => _finished.isCompleted;

  /// 流程结束时完成，值是 done、rejected 或 failed。
  Future<PairingStatus> get finished => _finished.future;

  /// 开始连接。邀请已过期时直接失败。
  void start() {
    if (_started || isFinished) return;
    _started = true;
    final ttl = invitation.ttl;
    if (ttl <= 0) {
      _finish(PairingStatus.failed, PairingFailure.expired);
      return;
    }
    _expiryTimer = Timer(Duration(seconds: ttl), () {
      if (!isFinished) _finish(PairingStatus.failed, PairingFailure.expired);
    });
    _channel.start();
  }

  /// 放弃配对：断开连接。中继上的邀请保持原状直到过期。
  Future<void> cancel() async {
    if (isFinished) return;
    _finish(PairingStatus.failed, PairingFailure.cancelled);
  }

  void _onFrame(Map<String, dynamic> frame);

  /// 中继明确告知邀请不可用（拒绝连接或带特定关闭码）。
  void _onTerminal(PairingFailure failure) => _finish(PairingStatus.failed, failure);

  /// 断线重连期间显示的状态。
  PairingStatus _statusWhileReconnecting() => _status;

  void _setStatus(PairingStatus status) {
    if (isFinished || _status == status) return;
    _status = status;
    _statusController.add(status);
  }

  void _finish(PairingStatus status, [PairingFailure? failure]) {
    if (isFinished) return;
    _status = status;
    _failure = failure;
    _expiryTimer?.cancel();
    _statusController.add(status);
    _finished.complete(status);
    unawaited(_channel.stop());
    unawaited(_statusController.close());
  }
}

/// 邀请人一侧：登记邀请、等请求、由用户批准或拒绝、发回应答。
class InviterPairing extends PairingFlow {
  InviterPairing({
    required super.baseUri,
    required super.connector,
    required super.identity,
    required super.invitation,
    required super.onPaired,
    required this.myName,
    super.backoff = _defaultBackoff,
    super.pingInterval = const Duration(seconds: 25),
  }) : super(role: 'inviter', sendExpiry: true);

  /// 批准时告诉对方的称呼。
  final Future<String> Function() myName;

  PairProfile? _requester;
  String? _safetyCode;
  bool _openingRequest = false;
  bool _deciding = false;
  bool _invalidRequest = false;
  bool _completing = false;
  ({bool accepted, String payload})? _response;
  PairedPeer? _peer;

  /// 请求方的资料；[status] 到 requestReceived 之后有值。
  PairProfile? get requester => _requester;

  /// 与请求方的安全码，供用户核对后再批准。
  String? get safetyCode => _safetyCode;

  @override
  void _onFrame(Map<String, dynamic> frame) {
    switch (frame['type']) {
      case 'welcome':
        final state = frame['state'];
        if (state == 'open') {
          _setStatus(PairingStatus.waiting);
        } else if (state == 'requested') {
          // 请求帧紧随其后。之前已经决定但应答没送到的，这里补发
          if (_response != null) _sendResponse();
        } else if (state == 'responded') {
          if (_response != null) {
            unawaited(_complete());
          } else {
            // 应答是上次运行时发的，会话 ID 已经不在内存里，无法恢复
            _finish(PairingStatus.failed, PairingFailure.used);
          }
        }
      case 'pair-request':
        final payload = frame['payload'];
        if (payload is String) unawaited(_openRequest(payload));
      case 'stored':
      case 'pair-done':
        if (_response != null) unawaited(_complete());
    }
  }

  @override
  void _onTerminal(PairingFailure failure) {
    // 应答已发出、对方已经确认完成的情况下，重连会被告知“邀请已用完”，这其实是成功
    if (failure == PairingFailure.used && _response != null) {
      unawaited(_complete());
      return;
    }
    super._onTerminal(failure);
  }

  @override
  PairingStatus _statusWhileReconnecting() =>
      _status == PairingStatus.waiting ? PairingStatus.connecting : _status;

  Future<void> _openRequest(String payload) async {
    if (_requester != null || _openingRequest || _response != null) return;
    _openingRequest = true;
    try {
      final profile = await PairingPayload.openRequest(
        payload: payload,
        inviterPrivateKey: identity.x25519PrivateKey,
        token: invitation.token,
      );
      if (isFinished) return;
      _requester = profile;
      _safetyCode = SafetyCode.compute(
        identity.x25519PublicKeyBase64,
        base64Url.encode(profile.x25519PublicKey),
      );
      _setStatus(PairingStatus.requestReceived);
    } on PairingPayloadException {
      if (isFinished) return;
      // 解不开的请求：替用户拒绝掉，让加入者那边得到明确结果
      _invalidRequest = true;
      _response = (accepted: false, payload: '');
      _setStatus(PairingStatus.responding);
      _sendResponse();
    } finally {
      _openingRequest = false;
    }
  }

  /// 批准请求。只在 [status] 为 requestReceived 时有效。
  Future<void> approve() async {
    final requester = _requester;
    if (_status != PairingStatus.requestReceived || requester == null || _deciding) return;
    _deciding = true;
    final sessionId = PairingPayload.newSessionId();
    final payload = await PairingPayload.sealResponse(
      inviterPrivateKey: identity.x25519PrivateKey,
      joinerPublicKey: requester.x25519PublicKey,
      token: invitation.token,
      sessionId: sessionId,
      inviter: PairProfile(
        x25519PublicKey: identity.x25519PublicKey,
        ed25519PublicKey: identity.ed25519PublicKey,
        name: _clampName(await myName()),
      ),
    );
    if (isFinished) return;
    _peer = PairedPeer(sessionId: sessionId, myRole: 'a', profile: requester);
    _response = (accepted: true, payload: payload);
    _setStatus(PairingStatus.responding);
    _sendResponse();
  }

  /// 拒绝请求。只在 [status] 为 requestReceived 时有效。
  void reject() {
    if (_status != PairingStatus.requestReceived || _deciding) return;
    _deciding = true;
    _response = (accepted: false, payload: '');
    _setStatus(PairingStatus.responding);
    _sendResponse();
  }

  void _sendResponse() {
    final response = _response;
    if (response == null) return;
    _channel.send({
      'type': 'pair-response',
      'accepted': response.accepted,
      'payload': response.payload,
    });
  }

  /// 应答已被中继收下（或对方已确认）：保存联系人并结束。
  Future<void> _complete() async {
    if (_completing || isFinished) return;
    _completing = true;
    final peer = _peer;
    if (peer == null) {
      _finish(
        _invalidRequest ? PairingStatus.failed : PairingStatus.rejected,
        _invalidRequest ? PairingFailure.invalidRequest : null,
      );
      return;
    }
    try {
      await onPaired(peer);
    } catch (_) {
      // 落库失败：不结束流程，下次收到中继的帧时再试
      _completing = false;
      return;
    }
    _finish(PairingStatus.done);
  }
}

/// 加入者一侧：发出加密的配对请求，等邀请人的应答。
class JoinerPairing extends PairingFlow {
  JoinerPairing({
    required super.baseUri,
    required super.connector,
    required super.identity,
    required super.invitation,
    required super.onPaired,
    required this.myName,
    super.backoff = _defaultBackoff,
    super.pingInterval = const Duration(seconds: 25),
  }) : super(role: 'joiner');

  /// 请求里告诉邀请人的称呼。
  final Future<String> Function() myName;

  String? _request;
  bool _sealing = false;
  bool _handlingResponse = false;

  @override
  void _onFrame(Map<String, dynamic> frame) {
    switch (frame['type']) {
      case 'welcome':
        final state = frame['state'];
        if (state == 'open') {
          unawaited(_sendRequest());
        } else if (state == 'requested') {
          // 能连上说明绑定的就是我们：请求已在中继上，等批准
          _setStatus(PairingStatus.waiting);
        }
      case 'stored':
        _setStatus(PairingStatus.waiting);
      case 'pair-response':
        final accepted = frame['accepted'];
        final payload = frame['payload'];
        if (accepted is bool && payload is String) {
          unawaited(_handleResponse(accepted, payload));
        }
      case 'error':
        if (frame['error'] == 'invite-used') {
          _finish(PairingStatus.failed, PairingFailure.used);
        }
    }
  }

  @override
  PairingStatus _statusWhileReconnecting() => PairingStatus.connecting;

  Future<void> _sendRequest() async {
    if (_sealing) return;
    if (_request == null) {
      _sealing = true;
      try {
        _request = await PairingPayload.sealRequest(
          inviterPublicKey: invitation.publicKey,
          token: invitation.token,
          joiner: PairProfile(
            x25519PublicKey: identity.x25519PublicKey,
            ed25519PublicKey: identity.ed25519PublicKey,
            name: _clampName(await myName()),
          ),
        );
      } finally {
        _sealing = false;
      }
    }
    if (isFinished) return;
    _channel.send({'type': 'pair-request', 'payload': _request});
  }

  Future<void> _handleResponse(bool accepted, String payload) async {
    if (_handlingResponse || isFinished) return;
    _handlingResponse = true;
    if (!accepted) {
      _channel.send({'type': 'pair-done'});
      _finish(PairingStatus.rejected);
      return;
    }
    final PairAcceptance acceptance;
    try {
      acceptance = await PairingPayload.openResponse(
        payload: payload,
        joinerPrivateKey: identity.x25519PrivateKey,
        inviterPublicKey: invitation.publicKey,
        token: invitation.token,
      );
      if (!_sameBytes(acceptance.inviter.x25519PublicKey, invitation.publicKey)) {
        throw const PairingPayloadException('inviter-key-mismatch');
      }
    } on PairingPayloadException {
      if (isFinished) return;
      _channel.send({'type': 'pair-done'});
      _finish(PairingStatus.failed, PairingFailure.invalidResponse);
      return;
    }
    if (isFinished) return;
    await onPaired(
      PairedPeer(sessionId: acceptance.sessionId, myRole: 'b', profile: acceptance.inviter),
    );
    // 先落库再告诉中继完成：反过来的话，中途退出会丢掉这次配对
    _channel.send({'type': 'pair-done'});
    _finish(PairingStatus.done);
  }
}

/// 去掉首尾空白并截到允许的长度（按 UTF-16 单元计，不拆开代理对）。
String _clampName(String name) {
  final buffer = StringBuffer();
  for (final rune in name.trim().runes) {
    final char = String.fromCharCode(rune);
    if (buffer.length + char.length > PairingPayload.maxNameLength) break;
    buffer.write(char);
  }
  return buffer.toString();
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
