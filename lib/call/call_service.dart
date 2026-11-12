/// 通话服务：一次只有一通通话，负责呼叫/响铃/接通/结束的状态机、超时和占线。
///
/// 信令经 [CallTransport] 收发（实际是加密后的临时消息，见 call_transport.dart），
/// 音频经 [CallMedia]（实际是 WebRTC）。两者都是接口，状态机本身不碰网络和设备。
/// 行为说明见 docs/call-signaling.md。
library;

import 'dart:async';

import '../contact/contact.dart';
import '../messaging/message_codec.dart';
import 'call_signal.dart';

/// 收到的一条通话信令：谁发的、内容（[CallSignal.encode] 的结果，未校验）。
class IncomingCallSignal {
  const IncomingCallSignal(this.contact, this.body);

  final Contact contact;
  final String body;
}

/// 通话信令的收发通道。
abstract class CallTransport {
  /// 把一条信令发给 [contact]。返回这条消息的 ID；与中继的连接没建立时返回 null（没有发出）。
  Future<String?> send(Contact contact, String body);

  /// 对方发来的信令（广播流）。
  Stream<IncomingCallSignal> get incoming;

  /// 因对方不在线被中继丢弃的消息：会话 ID 和 [send] 返回的消息 ID（广播流）。
  Stream<({String sessionId, String id})> get dropped;
}

/// 音频连接的状态。
enum CallMediaState { connected, failed }

/// 一通通话的音频连接（一个 WebRTC PeerConnection 加麦克风）。每通通话新建一个，用完 [close]。
abstract class CallMedia {
  /// 主叫：打开麦克风，生成 SDP offer。
  Future<String> createOffer();

  /// 被叫接听时：打开麦克风，应用对方的 offer，生成 SDP answer。
  Future<String> acceptOffer(String sdp);

  /// 主叫：应用对方的 answer。
  Future<void> acceptAnswer(String sdp);

  /// 加入对方的一个 ICE 候选。只能在 [acceptOffer] / [acceptAnswer] 完成之后调用。
  Future<void> addCandidate(CallCandidate candidate);

  /// 本端收集到的 ICE 候选。可能在 [createOffer] / [acceptOffer] 返回之前就开始发出。
  Stream<CallCandidate> get candidates;

  /// 连接状态变化。
  Stream<CallMediaState> get states;

  void setMuted(bool muted);

  /// 关闭连接、释放麦克风。可以重复调用。
  Future<void> close();
}

enum CallPhase {
  /// 没有通话。
  idle,

  /// 已呼出，等对方接听。
  outgoing,

  /// 有来电，等自己接听或拒接。
  incoming,

  /// 双方已交换 offer/answer，音频连接建立中。
  connecting,

  /// 通话中。
  active,

  /// 通话已结束，原因见 [CallSnapshot.endReason]；[CallService.dismiss] 或下一通通话开始后离开这个状态。
  ended,
}

enum CallEndReason {
  /// 自己挂断（包括呼出后自己取消）。
  hangup,

  /// 对方挂断。
  remoteHangup,

  /// 对方拒接。
  rejected,

  /// 自己拒接。
  declined,

  /// 对方正在通话中。
  busy,

  /// 对方不在线，或自己没连上中继。
  offline,

  /// 呼出后对方一直没接。
  timeout,

  /// 来电没接到：对方先挂了，或响铃超时。
  missed,

  /// 音频连接出错（任何一方）。
  failed,
}

/// 当前通话的状态。不可变；每次变化 [CallService.changes] 发出一个新的。
class CallSnapshot {
  const CallSnapshot({
    this.phase = CallPhase.idle,
    this.contact,
    this.callId,
    this.isOutgoing = false,
    this.remoteRinging = false,
    this.muted = false,
    this.connectedAt,
    this.endReason,
  });

  final CallPhase phase;

  /// 通话的对方。[CallPhase.idle] 时为 null。
  final Contact? contact;
  final String? callId;

  /// 这通通话是不是自己打出去的。
  final bool isOutgoing;

  /// 仅呼出：对方已经在响铃。
  final bool remoteRinging;
  final bool muted;

  /// 进入 [CallPhase.active] 的时刻。
  final DateTime? connectedAt;

  /// 仅 [CallPhase.ended]。
  final CallEndReason? endReason;
}

class CallService {
  CallService({
    required this.transport,
    required this.createMedia,
    this.ringTimeout = const Duration(seconds: 45),
    this.connectTimeout = const Duration(seconds: 30),
  }) {
    _transportSubscriptions.add(transport.incoming.listen(_onIncoming));
    _transportSubscriptions.add(transport.dropped.listen(_onDropped));
  }

  final CallTransport transport;

  /// 每通通话调用一次，新建它的音频连接。
  final CallMedia Function(Contact contact) createMedia;

  /// 呼出后对方不接、或来电自己不接，超过这么久就结束。
  final Duration ringTimeout;

  /// 进入 [CallPhase.connecting] 后音频连接超过这么久还没建立就结束。
  final Duration connectTimeout;

  final _changesController = StreamController<CallSnapshot>.broadcast();
  final _transportSubscriptions = <StreamSubscription<dynamic>>[];
  final _mediaSubscriptions = <StreamSubscription<dynamic>>[];

  /// 最近结束过的通话 callId，用来防重放。最多保留 64 个。
  final _endedCallIds = <String>[];

  CallSnapshot _snapshot = const CallSnapshot();
  CallMedia? _media;

  Timer? _ringTimer;
  Timer? _connectTimer;

  /// 呼出时 offer 临时消息的 ID；对方不在线时中继会把它丢回来。
  String? _offerMessageId;

  /// 来电时保存对方的 offer SDP，接听时传给 [CallMedia.acceptOffer]。
  String? _offerSdp;

  /// 自己的 offer / answer 还没发出时，本端先产生的 ICE 候选。
  final _localCandidates = <CallCandidate>[];

  /// [CallMedia.acceptOffer] / [CallMedia.acceptAnswer] 完成之前，对方先到的 ICE 候选。
  final _remoteCandidates = <CallCandidate>[];

  /// 自己的 offer / answer 是否已经（尝试）发出。
  bool _canSendCandidates = false;

  /// 对方 offer / answer 是否已经应用到媒体；完成前对方的候选只能先存起来。
  bool _acceptDone = false;

  bool _disposed = false;

  /// 当前状态。
  CallSnapshot get snapshot => _snapshot;

  /// 状态变化（广播流）。
  Stream<CallSnapshot> get changes => _changesController.stream;

  /// 呼叫 [contact]。当前有通话（不是 idle / ended）时抛 [StateError]。
  Future<void> start(Contact contact) async {
    if (_disposed) return;
    final phase = _snapshot.phase;
    if (phase == CallPhase.outgoing ||
        phase == CallPhase.incoming ||
        phase == CallPhase.connecting ||
        phase == CallPhase.active) {
      throw StateError('已有通话');
    }

    final callId = MessageCodec.newMessageId();
    _resetForNewCall();
    _emit(CallSnapshot(
      phase: CallPhase.outgoing,
      contact: contact,
      callId: callId,
      isOutgoing: true,
    ));

    try {
      final media = createMedia(contact);
      _media = media;
      _subscribeMedia(media, callId);
      final sdp = await media.createOffer();

      if (!_isSameCall(callId) || _snapshot.phase != CallPhase.outgoing) return;

      String? offerId;
      try {
        offerId = await transport.send(contact, CallSignal.offer(callId, sdp).encode());
      } catch (_) {
        offerId = null;
      }

      if (!_isSameCall(callId) || _snapshot.phase != CallPhase.outgoing) return;

      if (offerId == null) {
        _end(CallEndReason.offline);
        return;
      }

      _offerMessageId = offerId;
      _canSendCandidates = true;
      unawaited(_flushLocalCandidates(callId));
      _startRingTimer();
    } catch (_) {
      // createMedia / 订阅 / createOffer 失败：不发任何信令。
      if (_isSameCall(callId) && _snapshot.phase == CallPhase.outgoing) {
        _end(CallEndReason.failed);
      }
    }
  }

  /// 接听来电。不在 [CallPhase.incoming] 时无效果。
  Future<void> accept() async {
    if (_disposed) return;
    if (_snapshot.phase != CallPhase.incoming) return;

    final callId = _snapshot.callId!;
    final contact = _snapshot.contact!;
    final sdp = _offerSdp!;
    _ringTimer?.cancel();
    _ringTimer = null;

    try {
      final media = createMedia(contact);
      _media = media;
      _subscribeMedia(media, callId);
      if (_snapshot.muted) media.setMuted(true);

      final answerSdp = await media.acceptOffer(sdp);
      if (!_isSameCall(callId) || _snapshot.phase != CallPhase.incoming) return;

      _emit(CallSnapshot(
        phase: CallPhase.connecting,
        contact: contact,
        callId: callId,
        isOutgoing: false,
        muted: _snapshot.muted,
      ));
      _startConnectTimer(callId);

      // offer 已经应用，对方的候选从现在起可以直接加入，不用等 answer 发出去。
      _acceptDone = true;
      unawaited(_flushRemoteCandidates(callId));

      await _trySend(contact, CallSignal.answer(callId, answerSdp).encode());
      if (!_isSameCall(callId) ||
          (_snapshot.phase != CallPhase.connecting && _snapshot.phase != CallPhase.active)) {
        return;
      }

      _canSendCandidates = true;
      unawaited(_flushLocalCandidates(callId));
    } catch (_) {
      if (_isSameCall(callId) && _snapshot.phase == CallPhase.incoming) {
        await _trySend(contact, CallSignal.end(callId, CallSignal.reasonFailed).encode());
        if (_isSameCall(callId) && _snapshot.phase == CallPhase.incoming) {
          _end(CallEndReason.failed);
        }
      }
    }
  }

  /// 拒接来电。不在 [CallPhase.incoming] 时无效果。
  Future<void> decline() async {
    if (_disposed) return;
    if (_snapshot.phase != CallPhase.incoming) return;

    final callId = _snapshot.callId!;
    final contact = _snapshot.contact!;
    await _trySend(contact, CallSignal.end(callId, CallSignal.reasonReject).encode());
    if (_isSameCall(callId) && _snapshot.phase == CallPhase.incoming) {
      _end(CallEndReason.declined);
    }
  }

  /// 挂断（outgoing / connecting / active）。其它状态无效果。
  Future<void> hangup() async {
    if (_disposed) return;
    final phase = _snapshot.phase;
    if (phase != CallPhase.outgoing &&
        phase != CallPhase.connecting &&
        phase != CallPhase.active) {
      return;
    }

    final callId = _snapshot.callId!;
    final contact = _snapshot.contact!;
    await _trySend(contact, CallSignal.end(callId, CallSignal.reasonHangup).encode());
    if (_isSameCall(callId) &&
        (_snapshot.phase == CallPhase.outgoing ||
            _snapshot.phase == CallPhase.connecting ||
            _snapshot.phase == CallPhase.active)) {
      _end(CallEndReason.hangup);
    }
  }

  /// 静音或取消静音。没有通话时无效果。
  void setMuted(bool muted) {
    if (_disposed) return;
    final phase = _snapshot.phase;
    if (phase != CallPhase.outgoing &&
        phase != CallPhase.incoming &&
        phase != CallPhase.connecting &&
        phase != CallPhase.active) {
      return;
    }

    _emit(CallSnapshot(
      phase: phase,
      contact: _snapshot.contact,
      callId: _snapshot.callId,
      isOutgoing: _snapshot.isOutgoing,
      remoteRinging: _snapshot.remoteRinging,
      muted: muted,
      connectedAt: _snapshot.connectedAt,
      endReason: _snapshot.endReason,
    ));
    _media?.setMuted(muted);
  }

  /// 界面看过结束原因后调用：ended → idle。其它状态无效果。
  void dismiss() {
    if (_disposed) return;
    if (_snapshot.phase == CallPhase.ended) {
      _emit(const CallSnapshot());
    }
  }

  /// 结束当前通话（如果有，按挂断处理）并停止监听 [transport]。
  Future<void> dispose() async {
    if (_disposed) return;

    final phase = _snapshot.phase;
    if (phase == CallPhase.outgoing ||
        phase == CallPhase.connecting ||
        phase == CallPhase.active) {
      await hangup();
    } else if (phase == CallPhase.incoming) {
      await decline();
    }

    _disposed = true;
    for (final subscription in _transportSubscriptions) {
      await subscription.cancel();
    }
    _transportSubscriptions.clear();
    await _changesController.close();
  }

  // ---------------------------------------------------------------------------

  bool get _hasCall =>
      _snapshot.phase == CallPhase.outgoing ||
      _snapshot.phase == CallPhase.incoming ||
      _snapshot.phase == CallPhase.connecting ||
      _snapshot.phase == CallPhase.active;

  bool _isSameCall(String callId) => _snapshot.callId == callId;

  void _emit(CallSnapshot next) {
    _snapshot = next;
    if (!_changesController.isClosed) _changesController.add(next);
  }

  void _resetForNewCall() {
    _ringTimer?.cancel();
    _ringTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _closeMedia();
    _offerMessageId = null;
    _offerSdp = null;
    _localCandidates.clear();
    _remoteCandidates.clear();
    _canSendCandidates = false;
    _acceptDone = false;
  }

  void _closeMedia() {
    for (final subscription in _mediaSubscriptions) {
      unawaited(subscription.cancel());
    }
    _mediaSubscriptions.clear();
    final media = _media;
    _media = null;
    if (media != null) unawaited(media.close());
  }

  void _subscribeMedia(CallMedia media, String callId) {
    _mediaSubscriptions.add(media.candidates.listen((candidate) {
      _onLocalCandidate(callId, candidate);
    }));
    _mediaSubscriptions.add(media.states.listen((state) {
      _onMediaState(callId, state);
    }));
  }

  void _end(CallEndReason reason) {
    final callId = _snapshot.callId;
    final contact = _snapshot.contact;
    final isOutgoing = _snapshot.isOutgoing;

    _ringTimer?.cancel();
    _ringTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _closeMedia();

    if (callId != null) _rememberEnded(callId);

    _emit(CallSnapshot(
      phase: CallPhase.ended,
      contact: contact,
      callId: callId,
      isOutgoing: isOutgoing,
      endReason: reason,
    ));
  }

  void _rememberEnded(String callId) {
    if (_endedCallIds.contains(callId)) return;
    _endedCallIds.add(callId);
    while (_endedCallIds.length > 64) {
      _endedCallIds.removeAt(0);
    }
  }

  void _startRingTimer() {
    _ringTimer?.cancel();
    _ringTimer = Timer(ringTimeout, () {
      _ringTimer = null;
      unawaited(_onRingTimeout());
    });
  }

  Future<void> _onRingTimeout() async {
    if (_disposed) return;
    final phase = _snapshot.phase;
    if (phase == CallPhase.outgoing) {
      final callId = _snapshot.callId;
      final contact = _snapshot.contact;
      if (callId == null || contact == null) return;
      await _trySend(contact, CallSignal.end(callId, CallSignal.reasonHangup).encode());
      if (_isSameCall(callId) && _snapshot.phase == CallPhase.outgoing) {
        _end(CallEndReason.timeout);
      }
    } else if (phase == CallPhase.incoming) {
      _end(CallEndReason.missed);
    }
  }

  void _startConnectTimer(String callId) {
    _connectTimer?.cancel();
    _connectTimer = Timer(connectTimeout, () {
      _connectTimer = null;
      unawaited(_onConnectTimeout(callId));
    });
  }

  Future<void> _onConnectTimeout(String callId) async {
    if (_disposed) return;
    if (!_isSameCall(callId) || _snapshot.phase != CallPhase.connecting) return;
    final contact = _snapshot.contact;
    if (contact == null) return;
    await _trySend(contact, CallSignal.end(callId, CallSignal.reasonFailed).encode());
    if (_isSameCall(callId) && _snapshot.phase == CallPhase.connecting) {
      _end(CallEndReason.failed);
    }
  }

  Future<void> _trySend(Contact contact, String body) async {
    try {
      await transport.send(contact, body);
    } catch (_) {
      // 非 offer 信令发送失败一律忽略，不影响状态。
    }
  }

  void _onIncoming(IncomingCallSignal message) {
    if (_disposed) return;
    final signal = CallSignal.decode(message.body);
    if (signal == null) return;

    if (signal.kind == CallSignal.kindOffer) {
      _onOffer(message.contact, signal);
      return;
    }

    // 除了 offer，只有当前通话对方、且 callId 匹配的信令才处理。
    if (!_hasCall) return;
    if (_snapshot.contact?.sessionId != message.contact.sessionId) return;
    if (signal.callId != _snapshot.callId) return;

    switch (signal.kind) {
      case CallSignal.kindRinging:
        _onRinging();
        break;
      case CallSignal.kindAnswer:
        unawaited(_onAnswer(signal));
        break;
      case CallSignal.kindCandidate:
        _onCandidate(signal);
        break;
      case CallSignal.kindEnd:
        _onEnd(signal);
        break;
    }
  }

  void _onDropped(({String sessionId, String id}) dropped) {
    if (_disposed) return;
    if (_snapshot.phase != CallPhase.outgoing) return;
    if (_offerMessageId == null || dropped.id != _offerMessageId) return;
    if (_snapshot.contact?.sessionId != dropped.sessionId) return;
    _end(CallEndReason.offline);
  }

  void _onOffer(Contact contact, CallSignal signal) {
    if (_endedCallIds.contains(signal.callId)) return;

    final phase = _snapshot.phase;
    if (phase == CallPhase.idle || phase == CallPhase.ended) {
      _resetForNewCall();
      _offerSdp = signal.sdp;
      _emit(CallSnapshot(
        phase: CallPhase.incoming,
        contact: contact,
        callId: signal.callId,
        isOutgoing: false,
      ));
      unawaited(_trySend(contact, CallSignal.ringing(signal.callId).encode()));
      _startRingTimer();
      return;
    }

    // 当前有通话：完全相同的 offer 是重复投递；否则回 busy，不影响当前通话。
    if (_snapshot.contact?.sessionId == contact.sessionId &&
        _snapshot.callId == signal.callId) {
      return;
    }
    unawaited(_trySend(contact, CallSignal.end(signal.callId, CallSignal.reasonBusy).encode()));
  }

  void _onRinging() {
    if (_snapshot.phase != CallPhase.outgoing) return;
    if (_snapshot.remoteRinging) return;
    _emit(CallSnapshot(
      phase: CallPhase.outgoing,
      contact: _snapshot.contact,
      callId: _snapshot.callId,
      isOutgoing: true,
      remoteRinging: true,
      muted: _snapshot.muted,
    ));
  }

  Future<void> _onAnswer(CallSignal signal) async {
    if (_snapshot.phase != CallPhase.outgoing) return;
    final media = _media;
    if (media == null) return;

    final callId = _snapshot.callId!;
    final sdp = signal.sdp!;
    _ringTimer?.cancel();
    _ringTimer = null;

    _emit(CallSnapshot(
      phase: CallPhase.connecting,
      contact: _snapshot.contact,
      callId: callId,
      isOutgoing: true,
      muted: _snapshot.muted,
    ));
    _startConnectTimer(callId);

    try {
      await media.acceptAnswer(sdp);
    } catch (_) {
      if (_isSameCall(callId) && _snapshot.phase == CallPhase.connecting) {
        final contact = _snapshot.contact;
        if (contact != null) {
          await _trySend(contact, CallSignal.end(callId, CallSignal.reasonFailed).encode());
        }
        if (_isSameCall(callId) && _snapshot.phase == CallPhase.connecting) {
          _end(CallEndReason.failed);
        }
      }
      return;
    }

    if (!_isSameCall(callId) ||
        (_snapshot.phase != CallPhase.connecting && _snapshot.phase != CallPhase.active)) {
      return;
    }
    _acceptDone = true;
    await _flushRemoteCandidates(callId);
  }

  void _onCandidate(CallSignal signal) {
    final candidate = signal.candidate;
    if (candidate == null) return;
    if (_acceptDone) {
      unawaited(_addRemoteCandidate(candidate));
    } else {
      _remoteCandidates.add(candidate);
    }
  }

  void _onEnd(CallSignal signal) {
    if (_snapshot.phase == CallPhase.incoming) {
      _end(CallEndReason.missed);
      return;
    }

    final reason = signal.reason;
    final CallEndReason endReason;
    switch (reason) {
      case CallSignal.reasonReject:
        endReason = CallEndReason.rejected;
        break;
      case CallSignal.reasonBusy:
        endReason = CallEndReason.busy;
        break;
      case CallSignal.reasonFailed:
        endReason = CallEndReason.failed;
        break;
      default:
        endReason = CallEndReason.remoteHangup;
        break;
    }
    _end(endReason);
  }

  void _onLocalCandidate(String callId, CallCandidate candidate) {
    if (_disposed) return;
    if (!_isSameCall(callId)) return;
    if (_snapshot.phase == CallPhase.idle || _snapshot.phase == CallPhase.ended) return;

    if (_canSendCandidates) {
      unawaited(_sendCandidate(callId, candidate));
    } else {
      _localCandidates.add(candidate);
    }
  }

  void _onMediaState(String callId, CallMediaState state) {
    if (_disposed) return;
    if (!_isSameCall(callId)) return;

    final phase = _snapshot.phase;
    if (state == CallMediaState.connected) {
      if (phase == CallPhase.connecting) {
        _connectTimer?.cancel();
        _connectTimer = null;
        _emit(CallSnapshot(
          phase: CallPhase.active,
          contact: _snapshot.contact,
          callId: callId,
          isOutgoing: _snapshot.isOutgoing,
          muted: _snapshot.muted,
          connectedAt: DateTime.now(),
        ));
      }
    } else if (state == CallMediaState.failed) {
      if (phase == CallPhase.connecting || phase == CallPhase.active) {
        unawaited(_onMediaFailed(callId));
      }
    }
  }

  Future<void> _onMediaFailed(String callId) async {
    final contact = _snapshot.contact;
    if (contact == null) return;
    await _trySend(contact, CallSignal.end(callId, CallSignal.reasonFailed).encode());
    if (_isSameCall(callId) &&
        (_snapshot.phase == CallPhase.connecting || _snapshot.phase == CallPhase.active)) {
      _end(CallEndReason.failed);
    }
  }

  Future<void> _sendCandidate(String callId, CallCandidate candidate) async {
    final contact = _snapshot.contact;
    if (contact == null) return;
    await _trySend(contact, CallSignal.candidate(callId, candidate).encode());
  }

  Future<void> _flushLocalCandidates(String callId) async {
    while (_localCandidates.isNotEmpty) {
      if (!_isSameCall(callId) ||
          _snapshot.phase == CallPhase.idle ||
          _snapshot.phase == CallPhase.ended) {
        return;
      }
      final candidate = _localCandidates.removeAt(0);
      await _sendCandidate(callId, candidate);
    }
  }

  Future<void> _addRemoteCandidate(CallCandidate candidate) async {
    final media = _media;
    if (media == null) return;
    try {
      await media.addCandidate(candidate);
    } catch (_) {
      // 媒体已经关闭或出错：忽略。
    }
  }

  Future<void> _flushRemoteCandidates(String callId) async {
    while (_remoteCandidates.isNotEmpty) {
      if (!_isSameCall(callId) ||
          _snapshot.phase == CallPhase.idle ||
          _snapshot.phase == CallPhase.ended) {
        return;
      }
      final candidate = _remoteCandidates.removeAt(0);
      await _addRemoteCandidate(candidate);
    }
  }
}
