/// 会话中继客户端：维持到 `/session/<id>` 的连接，负责重连、重发和确认。
///
/// 协议见 docs/relay-protocol.md 第一节。本类不做加解密，payload 是不透明字符串。
library;

import 'dart:async';
import 'dart:convert';

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

/// 待确认队列中的一条消息。
class _PendingMessage {
  const _PendingMessage(this.id, this.payload);
  final String id;
  final String payload;
}

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

  /// 第 n 次连续失败后等待 `backoff[n-1]` 再连，超出列表长度后一直用最后一项。
  final List<Duration> backoff;
  final Duration pingInterval;
  final Duration pongTimeout;

  // =========================================================================
  // Private state
  // =========================================================================

  final _stateController = StreamController<SessionLinkState>.broadcast();
  SessionLinkState _state = SessionLinkState.disconnected;

  final _peerOnlineController = StreamController<bool>.broadcast();
  bool _peerOnline = false;

  final _storedController = StreamController<String>.broadcast();
  final _deliveredController = StreamController<String>.broadcast();
  final _droppedController = StreamController<String>.broadcast();
  final _errorsController = StreamController<RelayError>.broadcast();

  /// 待确认消息队列，按发送顺序。
  final List<_PendingMessage> _pending = [];
  /// 队列中 id 的集合，用于重复 send 去重。
  final Set<String> _pendingIds = {};

  RelayConnection? _connection;
  StreamSubscription<String>? _subscription;
  int _connectionGeneration = 0;
  bool _connectionActive = false;

  Timer? _pingTimer;
  Timer? _pongTimeoutTimer;
  Timer? _reconnectTimer;

  /// 已 stop 后不再允许建立新连接或重连。
  bool _stopped = false;

  int _consecutiveFailures = 0;

  // =========================================================================
  // Public getters
  // =========================================================================

  /// 当前状态。
  SessionLinkState get state => _state;

  /// 状态变化（广播流，只在状态确实改变时发出）。
  Stream<SessionLinkState> get states => _stateController.stream;

  /// 对方此刻是否在线。未连接时为 false。
  bool get peerOnline => _peerOnline;

  /// 对方在线状态变化（广播流，只在值确实改变时发出）。
  Stream<bool> get peerOnlineChanges => _peerOnlineController.stream;

  /// 中继已确认入队（`stored`）的消息 ID（广播流）。
  Stream<String> get stored => _storedController.stream;

  /// 对方已确认收到（`delivered`）的消息 ID（广播流）。
  Stream<String> get delivered => _deliveredController.stream;

  /// 因对方不在线而被丢弃（`dropped`）的临时消息 ID（广播流）。
  Stream<String> get dropped => _droppedController.stream;

  /// 错误（广播流）：中继的 `error` 帧，以及 `RelayError('replaced')`。
  Stream<RelayError> get errors => _errorsController.stream;

  /// 已调用 [send]、但还没收到 `stored` 的消息 ID，按 [send] 的顺序。
  List<String> get pendingIds => _pending.map((m) => m.id).toList();

  // =========================================================================
  // Public methods
  // =========================================================================

  /// 开始连接，并在断开后自动重连，直到 [stop]。重复调用无效果。
  void start() {
    if (_state == SessionLinkState.connecting ||
        _state == SessionLinkState.connected ||
        _reconnectTimer != null) {
      return;
    }
    _stopped = false;
    _connect();
  }

  /// 停止：关闭连接，取消所有定时器，不再重连。未确认的消息仍保留在 [pendingIds] 里。
  Future<void> stop() async {
    _stopped = true;
    _connectionActive = false;

    // Cancel all timers first so no timer can fire during shutdown.
    _pingTimer?.cancel();
    _pongTimeoutTimer?.cancel();
    _reconnectTimer?.cancel();

    // Close the connection now so closedByClient is set.
    final connection = _connection;
    _connection = null;
    if (connection != null) {
      unawaited(connection.close());
    }

    _setState(SessionLinkState.disconnected);
    _setPeerOnline(false);

    // Cancel subscription.
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }
  }

  /// 发送一条需要可靠送达的消息。已连接则立即发出；否则先留在待发队列，
  /// 连上（收到 `welcome`）后按顺序发出。收到 `stored` 之前断线的，重连后重发。
  void send(String id, String payload) {
    if (_pendingIds.contains(id)) return;
    _pending.add(_PendingMessage(id, payload));
    _pendingIds.add(id);

    if (_state == SessionLinkState.connected && _connectionActive) {
      _sendFrame({'type': 'msg', 'id': id, 'payload': payload});
    }
  }

  /// 发送一条临时消息（通话信令）。未连接时返回 false 且不发送、不排队。
  bool sendEphemeral(String id, String payload) {
    if (_state != SessionLinkState.connected || !_connectionActive) return false;
    _sendFrame({'type': 'msg', 'id': id, 'payload': payload, 'ephemeral': true});
    return true;
  }

  // =========================================================================
  // Private: connection lifecycle
  // =========================================================================

  Uri _buildUri() => baseUri.replace(
        path: '/session/$sessionId',
        queryParameters: {'peer': peer},
      );

  void _connect() {
    if (_stopped) return;

    _setState(SessionLinkState.connecting);

    connector(_buildUri()).then((connection) {
      if (_stopped) {
        unawaited(connection.close());
        return;
      }
      _establish(connection);
    }, onError: (_) {
      if (_stopped) return;
      _handleFailure();
    });
  }

  void _establish(RelayConnection connection) {
    _connection = connection;
    _connectionGeneration++;
    _connectionActive = true;
    final generation = _connectionGeneration;

    _subscription = connection.frames.listen(
      (frame) => _handleFrame(frame, generation),
      onDone: () => _handleConnectionDone(generation, connection.closeCode),
      onError: (_) => _handleConnectionDone(generation, connection.closeCode),
    );
  }

  void _handleFailure() {
    _consecutiveFailures++;
    _setState(SessionLinkState.disconnected);
    _setPeerOnline(false);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final index = _consecutiveFailures - 1;
    final delay = index < backoff.length ? backoff[index] : backoff.last;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_stopped) return;
      _connect();
    });
  }

  void _handleConnectionDone(int generation, int? closeCode) {
    if (generation != _connectionGeneration) return;
    if (_stopped) return;

    _connectionActive = false;
    _pingTimer?.cancel();
    _pongTimeoutTimer?.cancel();
    _subscription = null;

    _setPeerOnline(false);

    if (closeCode == 4001) {
      _setState(SessionLinkState.disconnected);
      _errorsController.add(const RelayError('replaced'));
      return;
    }

    _handleFailure();
  }

  // =========================================================================
  // Private: ping / pong heartbeat
  // =========================================================================

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer(pingInterval, () {
      _sendPing();
      _startPingTimer();
    });
  }

  void _sendPing() {
    if (!_connectionActive) return;
    _sendFrame({'type': 'ping'});
    _startPongTimeoutTimer();
  }

  void _startPongTimeoutTimer() {
    _pongTimeoutTimer?.cancel();
    _pongTimeoutTimer = Timer(pongTimeout, () {
      if (!_connectionActive) return;
      unawaited(_connection?.close());
    });
  }

  // =========================================================================
  // Private: frame handling
  // =========================================================================

  void _handleFrame(String frame, int generation) {
    if (generation != _connectionGeneration) return;

    Map<String, dynamic> json;
    try {
      json = jsonDecode(frame) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = json['type'];
    switch (type) {
      case 'welcome':
        _handleWelcome(json, generation);
        break;
      case 'msg':
        _handleMsg(json, generation);
        break;
      case 'stored':
        _handleStored(json);
        break;
      case 'delivered':
        if (json['id'] is String) {
          _deliveredController.add(json['id']);
        }
        break;
      case 'dropped':
        if (json['id'] is String) {
          _droppedController.add(json['id']);
        }
        break;
      case 'peer-online':
        _setPeerOnline(true);
        break;
      case 'peer-offline':
        _setPeerOnline(false);
        break;
      case 'error':
        _handleError(json);
        break;
      case 'ping':
        _sendFrame({'type': 'pong'});
        break;
      case 'pong':
        _pongTimeoutTimer?.cancel();
        break;
      default:
        // unrecognized type: ignore
        break;
    }
  }

  void _handleWelcome(Map<String, dynamic> json, int generation) {
    if (generation != _connectionGeneration) return;

    _consecutiveFailures = 0;
    _setState(SessionLinkState.connected);

    final peerOnline = json['peerOnline'] == true;
    _setPeerOnline(peerOnline);

    _sendPending();

    _startPingTimer();
  }

  void _handleStored(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String) return;
    _removePending(id);
    _storedController.add(id);
  }

  void _handleError(Map<String, dynamic> json) {
    final code = json['error'];
    if (code is! String) return;
    final id = json['id'];
    _errorsController.add(RelayError(code, id is String ? id : null));

    if (code == 'bad-id' || code == 'bad-payload' || code == 'too-large') {
      if (id is String) {
        _removePending(id);
      }
    }
  }

  void _handleMsg(Map<String, dynamic> json, int generation) {
    if (generation != _connectionGeneration) return;

    final id = json['id'];
    final payload = json['payload'];
    final ts = json['ts'];

    if (id is! String || payload is! String || ts is! int) return;

    final message = IncomingRelayMessage(id: id, payload: payload, ts: ts);
    _enqueueMessage(message, generation);
  }

  // =========================================================================
  // Private: ordered inbound message processing
  // =========================================================================

  /// 每条消息记着它是从哪一条连接（generation）收到的，ack 只发回那条连接。
  final List<(IncomingRelayMessage, int)> _messageQueue = [];
  bool _processingMessage = false;

  void _enqueueMessage(IncomingRelayMessage message, int generation) {
    _messageQueue.add((message, generation));
    _drainMessageQueue();
  }

  void _drainMessageQueue() {
    if (_processingMessage || _messageQueue.isEmpty) return;

    _processingMessage = true;
    final (message, generation) = _messageQueue.removeAt(0);

    Future<void> result;
    try {
      result = onMessage(message);
    } catch (_) {
      result = Future<void>.error('onMessage threw synchronously');
    }

    unawaited(result.then((_) {
      _processingMessage = false;
      if (_connectionActive && generation == _connectionGeneration) {
        _sendFrame({'type': 'ack', 'id': message.id});
      }
      _drainMessageQueue();
    }, onError: (_) {
      _processingMessage = false;
      _drainMessageQueue();
    }));
  }

  // =========================================================================
  // Private: helpers
  // =========================================================================

  void _sendPending() {
    for (final message in _pending) {
      _sendFrame({'type': 'msg', 'id': message.id, 'payload': message.payload});
    }
  }

  void _removePending(String id) {
    _pending.removeWhere((m) => m.id == id);
    _pendingIds.remove(id);
  }

  void _sendFrame(Map<String, dynamic> frame) {
    if (!_connectionActive) return;
    try {
      _connection?.send(jsonEncode(frame));
    } catch (_) {
      // connection may have closed; ignore
    }
  }

  void _setState(SessionLinkState newState) {
    if (_state == newState) return;
    _state = newState;
    _stateController.add(newState);
  }

  void _setPeerOnline(bool value) {
    if (_peerOnline == value) return;
    _peerOnline = value;
    _peerOnlineController.add(value);
  }
}
