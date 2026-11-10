/// 会话中继客户端：维持到 `/session/<id>` 的连接，负责重连、重发和确认。
///
/// 协议见 docs/relay-protocol.md 第一节。本类不做加解密，payload 是不透明字符串。
library;

import 'dart:async';

import 'relay_transport.dart';

/// 连接状态。只有收到 `welcome` 之后才算 [connected]。
enum SessionLinkState { disconnected, connecting, connected }

/// 中继投递过来的一条消息。
class IncomingRelayMessage {
  const IncomingRelayMessage({required this.id, required this.payload, required this.ts});

  final String id;
  final String payload;

  /// 中继收到该消息时的毫秒时间戳。
  final int ts;
}

/// 处理一条收到的消息。正常返回后客户端才向中继发 `ack`；抛异常则不 ack，
/// 中继会在下次重连时再次投递。处理方需要自己按 id 去重。
typedef RelayMessageHandler = Future<void> Function(IncomingRelayMessage message);

class SessionClient {
  SessionClient({
    required this.baseUri,
    required this.sessionId,
    required this.peer,
    required this.connector,
    required this.onMessage,
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 30),
    ],
    this.pingInterval = const Duration(seconds: 25),
    this.pongTimeout = const Duration(seconds: 10),
  });

  /// 中继地址，例如 `wss://whisper.tommydeng.org`。
  final Uri baseUri;
  final String sessionId;

  /// `a`（邀请人）或 `b`（加入者）。
  final String peer;
  final RelayConnector connector;
  final RelayMessageHandler onMessage;

  /// 第 n 次连续失败后等待 `backoff[n-1]` 再连，超出长度后一直用最后一项。
  final List<Duration> backoff;
  final Duration pingInterval;
  final Duration pongTimeout;

  /// 当前状态。
  SessionLinkState get state => throw UnimplementedError();

  /// 状态变化（广播流，只在状态确实改变时发出）。
  Stream<SessionLinkState> get states => throw UnimplementedError();

  /// 对方此刻是否在线。未连接时为 false。
  bool get peerOnline => throw UnimplementedError();

  /// 对方在线状态变化（广播流，只在值确实改变时发出）。
  Stream<bool> get peerOnlineChanges => throw UnimplementedError();

  /// 中继已确认入队（`stored`）的消息 ID（广播流）。
  Stream<String> get stored => throw UnimplementedError();

  /// 对方已确认收到（`delivered`）的消息 ID（广播流）。
  Stream<String> get delivered => throw UnimplementedError();

  /// 因对方不在线而被丢弃（`dropped`）的临时消息 ID（广播流）。
  Stream<String> get dropped => throw UnimplementedError();

  /// 错误（广播流）：中继的 `error` 帧，以及 `RelayError('replaced')`。
  Stream<RelayError> get errors => throw UnimplementedError();

  /// 已调用 [send]、但还没收到 `stored` 的消息 ID，按 [send] 的顺序。
  List<String> get pendingIds => throw UnimplementedError();

  /// 开始连接，并在断开后自动重连，直到 [stop]。重复调用无效果。
  void start() => throw UnimplementedError();

  /// 停止：关闭连接，取消所有定时器，不再重连。未确认的消息仍保留在 [pendingIds] 里。
  Future<void> stop() => throw UnimplementedError();

  /// 发送一条需要可靠送达的消息。已连接则立即发出；否则先留在待发队列，
  /// 连上（收到 `welcome`）后按顺序发出。收到 `stored` 之前断线的，重连后重发。
  void send(String id, String payload) => throw UnimplementedError();

  /// 发送一条临时消息（通话信令）。未连接时返回 false 且不发送、不排队。
  bool sendEphemeral(String id, String payload) => throw UnimplementedError();
}
