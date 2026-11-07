/// 耳语直接文字直连模块。
///
/// 基于 WebRTC DataChannel 实现双方文字消息的直连传输，
/// 不经过 Durable Object 中继，适用于局域网/ZeroTier 直连场景。

import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// 直接文字直连服务
class DirectTextService {
  RTCDataChannel? _dc;
  void Function(String text)? onMessageReceived;

  /// 绑定数据通道，收到文字消息时通过 [onMessageReceived] 回调
  void setDataChannel(RTCDataChannel dc) {
    _dc = dc;
    dc.onMessage = (message) {
      if (message.isBinary) return;
      final text = message.text;
      final decoded = _decode(text);
      if (decoded != null) {
        onMessageReceived?.call(decoded);
      }
    };
  }

  /// 发送文字消息
  Future<bool> sendText(String text) async {
    if (_dc == null || _dc!.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    final msg = _encode(text);
    try {
      await _dc!.send(RTCDataChannelMessage(msg));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 编码文本消息为 JSON 字符串
  static String _encode(String text) {
    return jsonEncode({'t': 'text', 'body': text});
  }

  /// 解码文本消息
  static String? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['t'] == 'text' && decoded['body'] is String) {
        return decoded['body'] as String;
      }
    } catch (_) {
      // 忽略无法解析的消息
    }
    return null;
  }

  /// 断开连接
  void dispose() {
    _dc = null;
    onMessageReceived = null;
  }
}
