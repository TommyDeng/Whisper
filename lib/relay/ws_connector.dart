/// [RelayConnector] 的真实实现：基于 dart:io 的 WebSocket。
///
/// 不直接用 `WebSocket.connect`，因为它在升级被拒绝时拿不到 HTTP 状态码和响应体，
/// 而配对流程需要区分 404 / 410 等拒绝原因。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'relay_transport.dart';

const _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// 连接中继。`ws://` / `wss://` 地址。
Future<RelayConnection> connectWebSocket(
  Uri uri, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final httpUri = uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http');
  final client = HttpClient()..connectionTimeout = timeout;
  var handedOver = false;
  try {
    final random = Random.secure();
    final key = base64.encode(List<int>.generate(16, (_) => random.nextInt(256)));

    final request = await client.openUrl('GET', httpUri).timeout(timeout);
    request.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Key', key)
      ..set('Sec-WebSocket-Version', '13');
    final response = await request.close().timeout(timeout);

    if (response.statusCode != HttpStatus.switchingProtocols) {
      throw RelayRejected(response.statusCode, await _readError(response, timeout));
    }
    final expected = base64.encode(sha1.convert(ascii.encode('$key$_webSocketGuid')).bytes);
    if (response.headers.value('sec-websocket-accept') != expected) {
      throw const WebSocketException('bad Sec-WebSocket-Accept');
    }

    final socket = await response.detachSocket();
    handedOver = true;
    return _WebSocketConnection(WebSocket.fromUpgradedSocket(socket, serverSide: false));
  } finally {
    client.close(force: !handedOver);
  }
}

/// 读出 `{"ok":false,"error":<码>}` 里的错误码；读不到就返回 null。
Future<String?> _readError(HttpClientResponse response, Duration timeout) async {
  try {
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > 4096) return null;
    }
    final body = jsonDecode(utf8.decode(bytes));
    if (body is Map && body['error'] is String) return body['error'] as String;
  } catch (_) {
    // 响应体不是预期格式：只保留状态码
  }
  return null;
}

class _WebSocketConnection implements RelayConnection {
  _WebSocketConnection(this._socket) {
    _socket.listen(
      (data) {
        // 中继只发文本帧，二进制帧直接丢弃
        if (data is String && !_ended) _frames.add(data);
      },
      onDone: () => _end(_socket.closeCode),
      onError: (_) => _end(_socket.closeCode),
      cancelOnError: true,
    );
  }

  final WebSocket _socket;
  final StreamController<String> _frames = StreamController<String>();
  bool _ended = false;
  int? _closeCode;

  @override
  Stream<String> get frames => _frames.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void send(String frame) {
    if (_ended) throw StateError('connection closed');
    _socket.add(frame);
  }

  @override
  Future<void> close([int code = 1000]) async {
    if (_ended) return;
    // 先结束帧流再关底层连接：网络已断时关闭握手可能很久才返回，上层不应该等它。
    _end(code);
    try {
      await _socket.close(code).timeout(const Duration(seconds: 5));
    } catch (_) {
      // 关闭握手失败或超时：连接反正已经不用了
    }
  }

  void _end(int? code) {
    if (_ended) return;
    _ended = true;
    _closeCode = code;
    unawaited(_frames.close());
  }
}
