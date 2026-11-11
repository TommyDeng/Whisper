/// 本地数据库的整库加密。
///
/// SQLite 用的是带加密支持的 SQLite3 Multiple Ciphers 构建（见 pubspec.yaml 的 hooks 配置），
/// 密钥是 32 字节随机数，存在系统安全存储里，不落盘到别处。
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

class DbEncryption {
  DbEncryption._();

  static final _keyPattern = RegExp(r'^[0-9a-f]{64}$');
  static const _plainHeader = 'SQLite format 3\u0000';

  /// 新的随机密钥：32 字节，小写十六进制。
  static String newKey() {
    final random = Random.secure();
    return List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static bool isValidKey(String key) => _keyPattern.hasMatch(key);

  /// 给刚打开的连接设置密钥。必须是这条连接上的第一条语句。
  static Future<void> applyKey(Database db, String key) async {
    _check(key);
    // PRAGMA 不支持绑定参数；key 已校验为纯十六进制，拼接是安全的
    await db.rawQuery("PRAGMA key = '$key'");
  }

  /// [path] 是否是一个没有加密的 SQLite 文件（旧版本留下的）。
  static Future<bool> isPlaintextFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    final raf = await file.open();
    try {
      final head = await raf.read(_plainHeader.length);
      return String.fromCharCodes(head) == _plainHeader;
    } finally {
      await raf.close();
    }
  }

  /// 把一个没有加密的库就地加密。数据保留。
  static Future<void> encryptInPlace(String path, String key) async {
    _check(key);
    final db = await openDatabase(path, singleInstance: false);
    try {
      await db.rawQuery("PRAGMA rekey = '$key'");
    } finally {
      await db.close();
    }
  }

  static void _check(String key) {
    if (!isValidKey(key)) throw ArgumentError('数据库密钥格式不对');
  }
}

/// 数据库密钥在系统安全存储里的存取。
class DbKeyStore {
  /// [profile] 非空时密钥名带上后缀，与 [IdentityStore] 的约定一致。
  DbKeyStore({FlutterSecureStorage? storage, String profile = ''})
      : _storage = storage ?? const FlutterSecureStorage(),
        _name = profile.isEmpty ? 'db_key' : 'db_key.$profile';

  final FlutterSecureStorage _storage;
  final String _name;

  /// 读出密钥；没有（或内容损坏）时返回 null。
  Future<String?> load() async {
    final value = await _storage.read(key: _name);
    return value != null && DbEncryption.isValidKey(value) ? value : null;
  }

  /// 生成并保存一把新密钥。
  Future<String> create() async {
    final key = DbEncryption.newKey();
    await _storage.write(key: _name, value: key);
    return key;
  }

  Future<void> clear() => _storage.delete(key: _name);
}
