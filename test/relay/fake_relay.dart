import 'dart:async';
import 'dart:convert';

import 'package:whisper/relay/relay_transport.dart';

/// 测试用的假连接：记录客户端发出的帧，测试代码可以推送帧或模拟断线。
class FakeConnection implements RelayConnection {
  FakeConnection(this.uri);

  final Uri uri;

  /// 客户端发出的帧（已解码），按发送顺序。
  final List<Map<String, dynamic>> sent = [];

  /// 客户端是否主动调用过 close。
  bool closedByClient = false;

  final StreamController<String> _controller = StreamController<String>();
  int? _closeCode;
  bool _ended = false;

  @override
  Stream<String> get frames => _controller.stream;

  @override
  int? get closeCode => _closeCode;

  bool get ended => _ended;

  @override
  void send(String frame) {
    if (_ended) throw StateError('connection closed');
    sent.add(jsonDecode(frame) as Map<String, dynamic>);
  }

  @override
  Future<void> close([int code = 1000]) async {
    closedByClient = true;
    _end(code);
  }

  /// 中继推送一帧。
  void push(Map<String, dynamic> frame) => _controller.add(jsonEncode(frame));

  /// 中继推送一段原始文本（用于畸形帧）。
  void pushRaw(String text) => _controller.add(text);

  /// 模拟连接被对端或网络断开。
  void drop([int code = 1006]) => _end(code);

  /// 指定 type 的已发送帧。
  List<Map<String, dynamic>> sentOfType(String type) =>
      sent.where((frame) => frame['type'] == type).toList();

  void _end(int code) {
    if (_ended) return;
    _ended = true;
    _closeCode = code;
    unawaited(_controller.close());
  }
}

/// 假中继：记录每次连接尝试，可切换为拒绝连接。
class FakeRelay {
  final List<Uri> attempts = [];
  final List<FakeConnection> connections = [];

  /// 为 true 时连接尝试抛异常（模拟网络不通）。
  bool refuse = false;

  Future<RelayConnection> connect(Uri uri) async {
    attempts.add(uri);
    if (refuse) throw Exception('network unreachable');
    final connection = FakeConnection(uri);
    connections.add(connection);
    return connection;
  }

  FakeConnection get last => connections.last;
}
