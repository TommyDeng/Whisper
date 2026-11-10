/// 邀请码生成与解析。
///
/// 邀请码格式（Base32 编码）：
///   version(1 byte) + publicKey(32 bytes) + token(16 bytes) + expiry(4 bytes)
///   总计 53 字节 -> Base32 85 字符
///
/// 邀请码特性：
/// - 一次性：使用后立即失效
/// - 24 小时有效：过期后自动作废
/// - 需手动批准：邀请人使用后，须邀请人手动批准才能建立会话

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// 邀请码数据。
class InvitationCode {
  const InvitationCode({
    required this.publicKey,
    required this.token,
    required this.expiry,
  });

  /// 邀请者的 X25519 公钥（32 字节）。
  final Uint8List publicKey;

  /// 一次性令牌（16 字节，随机生成）。
  final Uint8List token;

  /// 过期时间戳（Unix 秒）。
  final int expiry;

  /// Base32 编码的邀请码字符串（可复制粘贴）。
  String encode() {
    if (publicKey.length != 32) {
      throw ArgumentError('publicKey 必须为 32 字节');
    }
    if (token.length != 16) {
      throw ArgumentError('token 必须为 16 字节');
    }
    if (expiry < 0 || expiry > 0xFFFFFFFF) {
      throw ArgumentError('expiry 必须在 0..0xFFFFFFFF 范围内');
    }

    final bytes = <int>[];
    bytes.add(1); // version
    bytes.addAll(publicKey);
    bytes.addAll(token);
    bytes.addAll(_int32ToBytes(expiry));
    return _Base32.encode(bytes);
  }

  /// 从 Base32 字符串解析邀请码。
  static InvitationCode? decode(String code) {
    // 去掉允许的分隔符：空白字符（空格、制表符、回车、换行）和连字符
    final cleaned = StringBuffer();
    for (var i = 0; i < code.length; i++) {
      final ch = code[i];
      if (ch == '-' || ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
        continue;
      }
      cleaned.writeCharCode(ch.codeUnitAt(0));
    }
    final s = cleaned.toString();

    // 去掉分隔符后必须恰好 85 个字符
    if (s.length != 85) return null;

    // 忽略大小写，且所有字符必须在字母表内
    final upper = s.toUpperCase();
    for (var i = 0; i < upper.length; i++) {
      if (_Base32._alphabet.indexOf(upper[i]) == -1) return null;
    }

    // 最后一个字符的补位（最低位）必须为 0
    final lastIndex = _Base32._alphabet.indexOf(upper[84]);
    if (lastIndex.isOdd) return null;

    // Base32 解码
    final bytes = _Base32.decode(upper);
    if (bytes == null || bytes.length != 53) return null;

    // 版本号必须为 1
    if (bytes[0] != 1) return null;

    final publicKey = Uint8List.fromList(bytes.sublist(1, 33));
    final token = Uint8List.fromList(bytes.sublist(33, 49));
    final expiry = _bytesToInt32(bytes.sublist(49, 53));

    return InvitationCode(
      publicKey: publicKey,
      token: token,
      expiry: expiry,
    );
  }

  /// 邀请码是否已过期。
  bool get isExpired => DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiry;

  /// 剩余有效时间（秒）。
  int get ttl => expiry - (DateTime.now().millisecondsSinceEpoch ~/ 1000);

  /// 生成新的邀请码（24 小时有效）。
  static InvitationCode create(Uint8List publicKey) {
    if (publicKey.length != 32) {
      throw ArgumentError('publicKey 必须为 32 字节');
    }
    final token = Uint8List.fromList(
      List.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400; // 24h
    return InvitationCode(
      publicKey: Uint8List.fromList(publicKey),
      token: token,
      expiry: expiry,
    );
  }

  /// 邀请码用于配对请求的标识（token 的 Base64 编码，用于信令）。
  String get requestId => base64Url.encode(token);
}

int _bytesToInt32(List<int> bytes) {
  return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
}

List<int> _int32ToBytes(int value) {
  return [
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];
}

/// Base32 编码/解码（RFC 4648，无填充）。
class _Base32 {
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static String encode(List<int> bytes) {
    final result = StringBuffer();
    var bits = 0;
    var value = 0;
    for (final byte in bytes) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        result.writeCharCode(_alphabet.codeUnitAt((value >> bits) & 0x1F));
      }
    }
    if (bits > 0) {
      result.writeCharCode(_alphabet.codeUnitAt((value << (5 - bits)) & 0x1F));
    }
    return result.toString();
  }

  static List<int>? decode(String encoded) {
    final bytes = <int>[];
    var bits = 0;
    var value = 0;
    for (final ch in encoded.codeUnits) {
      final index = _alphabet.indexOf(String.fromCharCode(ch));
      if (index == -1) return null;
      value = (value << 5) | index;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        bytes.add((value >> bits) & 0xFF);
      }
    }
    return bytes;
  }
}
