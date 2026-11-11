/// 运行时配置。都来自环境变量，方便本地联调时同一台机器跑两个实例。
library;

import 'dart:io';

class AppConfig {
  AppConfig._();

  static const String defaultRelayUrl = 'wss://whisper.tommydeng.org';

  /// 中继地址。`WHISPER_RELAY_URL` 可覆盖，例如本地 `ws://127.0.0.1:8787`。
  static Uri get relayUri => parseRelayUrl(Platform.environment['WHISPER_RELAY_URL']);

  /// 本地数据隔离用的档案名。`WHISPER_PROFILE=alice` 时数据库和密钥存储都带上后缀，
  /// 同一个系统账号下可以并存多个身份。未设置时为空串。
  static String get profile => sanitizeProfile(Platform.environment['WHISPER_PROFILE']);

  /// `WHISPER_FORCE_RELAY=1` 时通话只走 TURN 中继，用来验证中继路径。
  static bool get forceRelay => Platform.environment['WHISPER_FORCE_RELAY'] == '1';

  /// 只接受 ws/wss，且非本机地址必须用 wss；不合法时回落到默认地址。
  static Uri parseRelayUrl(String? value) {
    final fallback = Uri.parse(defaultRelayUrl);
    if (value == null || value.trim().isEmpty) return fallback;
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.host.isEmpty) return fallback;
    if (uri.scheme == 'wss') return uri;
    const local = {'127.0.0.1', 'localhost', '::1'};
    if (uri.scheme == 'ws' && local.contains(uri.host)) return uri;
    return fallback;
  }

  /// 档案名只保留字母数字、下划线和连字符，最长 32 个字符。
  static String sanitizeProfile(String? value) {
    if (value == null) return '';
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
  }
}
