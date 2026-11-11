/// 通话服务：一次只有一通通话，负责呼叫/响铃/接通/结束的状态机、超时和占线。
///
/// 信令经 [CallTransport] 收发（实际是加密后的临时消息，见 call_transport.dart），
/// 音频经 [CallMedia]（实际是 WebRTC）。两者都是接口，状态机本身不碰网络和设备。
/// 行为说明见 docs/call-signaling.md。
library;

import 'dart:async';

import '../contact/contact.dart';
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
  });

  final CallTransport transport;

  /// 每通通话调用一次，新建它的音频连接。
  final CallMedia Function() createMedia;

  /// 呼出后对方不接、或来电自己不接，超过这么久就结束。
  final Duration ringTimeout;

  /// 进入 [CallPhase.connecting] 后音频连接超过这么久还没建立就结束。
  final Duration connectTimeout;

  /// 当前状态。
  CallSnapshot get snapshot => throw UnimplementedError();

  /// 状态变化（广播流）。
  Stream<CallSnapshot> get changes => throw UnimplementedError();

  /// 呼叫 [contact]。当前有通话（不是 idle / ended）时抛 [StateError]。
  Future<void> start(Contact contact) => throw UnimplementedError();

  /// 接听来电。不在 [CallPhase.incoming] 时无效果。
  Future<void> accept() => throw UnimplementedError();

  /// 拒接来电。不在 [CallPhase.incoming] 时无效果。
  Future<void> decline() => throw UnimplementedError();

  /// 挂断（outgoing / connecting / active）。其它状态无效果。
  Future<void> hangup() => throw UnimplementedError();

  /// 静音或取消静音。没有通话时无效果。
  void setMuted(bool muted) => throw UnimplementedError();

  /// 界面看过结束原因后调用：ended → idle。其它状态无效果。
  void dismiss() => throw UnimplementedError();

  /// 结束当前通话（如果有，按挂断处理）并停止监听 [transport]。
  Future<void> dispose() => throw UnimplementedError();
}
