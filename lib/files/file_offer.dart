import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'file_cipher.dart';

// 文件消息的正文：告诉对方去哪取文件、怎么解密、怎么校验。
// 格式见 docs/file-relay.md 的“文件消息”。

class FileOffer {
  FileOffer({
    required this.fileId,
    required this.name,
    required this.size,
    required this.keys,
    required Uint8List hash,
  }) : hash = Uint8List.fromList(hash) {
    if (!_fileIdPattern.hasMatch(fileId)) {
      throw const FormatException('文件 ID 不合法');
    }
    if (name.isEmpty || name.length > maxNameLength) {
      throw const FormatException('文件名为空或过长');
    }
    if (size < 0 || size > FileCipher.maxFileBytes) {
      throw const FormatException('文件大小超出范围');
    }
    if (hash.length != FileCipher.hashLength) {
      throw const FormatException('哈希长度不对');
    }
  }

  static const int maxNameLength = 255;

  static final _fileIdPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _random = Random.secure();

  /// 中继上的文件 ID（43 个 URL 安全字符）。
  final String fileId;

  /// 发送方给的文件名。不可信，存盘时用 [safeName]。
  final String name;

  /// 明文字节数。
  final int size;

  final FileKeys keys;

  /// 明文的 BLAKE2b-256。
  final Uint8List hash;

  /// 新的文件 ID：32 字节随机数的 base64url。
  static String newFileId() =>
      _b64(List<int>.generate(32, (_) => _random.nextInt(256)));

  /// 存盘用的文件名：只取最后一段路径，去掉控制字符和 Windows 不允许的字符。
  String get safeName => sanitizeName(name);

  static String sanitizeName(String name) {
    final last = name.split(RegExp(r'[/\\]')).last;
    final cleaned = last
        .replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '')
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'file';
    return cleaned;
  }

  String encode() => jsonEncode({
        'v': 1,
        'id': fileId,
        'name': name,
        'size': size,
        'key': _b64(keys.key),
        'np': _b64(keys.noncePrefix),
        'hash': _b64(hash),
      });

  /// 解析文件消息的正文。任何不合格的内容都抛 [FormatException]。
  static FileOffer decode(String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      throw const FormatException('不是合法的 JSON');
    }
    if (json is! Map<String, dynamic> || json['v'] != 1) {
      throw const FormatException('版本不对');
    }
    final id = json['id'];
    final name = json['name'];
    final size = json['size'];
    if (id is! String || name is! String || size is! int) {
      throw const FormatException('字段类型不对');
    }
    final key = _bytes(json['key'], FileKeys.keyLength);
    final noncePrefix = _bytes(json['np'], FileKeys.noncePrefixLength);
    final hash = _bytes(json['hash'], FileCipher.hashLength);
    return FileOffer(
      fileId: id,
      name: name,
      size: size,
      keys: FileKeys(key: key, noncePrefix: noncePrefix),
      hash: hash,
    );
  }

  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List _bytes(Object? value, int length) {
    if (value is! String) throw const FormatException('字段类型不对');
    final Uint8List bytes;
    try {
      bytes = base64Url.decode(base64Url.normalize(value));
    } catch (_) {
      throw const FormatException('不是合法的 base64url');
    }
    if (bytes.length != length) throw const FormatException('字段长度不对');
    return bytes;
  }
}
