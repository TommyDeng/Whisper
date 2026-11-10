/// 中继连接的传输层抽象。
///
/// 协议见 docs/relay-protocol.md。上层（[SessionClient] 等）只依赖这里的接口，
/// 测试里用假实现替换，真实实现基于 WebSocket。
library;

/// 一条已建立的中继连接（WebSocket 文本帧）。
abstract class RelayConnection {
  /// 收到的文本帧。连接结束（无论哪一方关闭、或网络断开）时流正常结束（done），
  /// 不以 error 结束。单订阅流。
  Stream<String> get frames;

  /// 发送一帧。连接已结束时抛 [StateError]。
  void send(String frame);

  /// 主动关闭连接。可重复调用。关闭后 [frames] 结束。
  Future<void> close([int code = 1000]);

  /// 连接结束后的 WebSocket 关闭码；尚未结束或拿不到时为 null。
  /// 中继用到的私有码：4001 被同一身份的新连接替换，4002 邀请过期，4003 邀请已被他人使用。
  int? get closeCode;
}

/// 建立连接。升级被中继以 HTTP 状态码拒绝时抛 [RelayRejected]；
/// 网络不通等其它失败抛任意异常。
typedef RelayConnector = Future<RelayConnection> Function(Uri uri);

/// 中继在 WebSocket 升级前拒绝了连接（响应体为 `{"ok":false,"error":<码>}`）。
class RelayRejected implements Exception {
  const RelayRejected(this.status, [this.error]);

  /// HTTP 状态码，例如 404、410。
  final int status;

  /// 中继给出的错误码，例如 `invite-used`；解析不到时为 null。
  final String? error;

  @override
  String toString() => 'RelayRejected($status, $error)';
}

/// 中继通过 `{"type":"error"}` 帧报告的错误，或客户端自己发现的连接级错误。
class RelayError {
  const RelayError(this.error, [this.id]);

  /// 错误码。中继的码见协议文档；客户端自己产生的有 `replaced`（被新连接替换，不再重连）。
  final String error;

  /// 相关的消息 ID（如果有）。
  final String? id;

  @override
  bool operator ==(Object other) =>
      other is RelayError && other.error == error && other.id == id;

  @override
  int get hashCode => Object.hash(error, id);

  @override
  String toString() => 'RelayError($error, $id)';
}
