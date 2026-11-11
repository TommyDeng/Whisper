/// 应用唯一的 SQLite 数据库：联系人、消息、待完成的邀请、设置都在这一个文件里。
///
/// 以前联系人和消息各自打开同一个文件、各自建表，谁先打开就只有谁的表。
/// 现在所有表都在这里创建，建表语句都是幂等的，升级时直接重跑一遍。
///
/// 文件整库加密，密钥在系统安全存储里（见 db_encryption.dart）。
library;

import 'dart:io';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../app_config.dart';
import 'db_encryption.dart';

class AppDatabase {
  AppDatabase._();

  static const int schemaVersion = 4;

  static Future<Database>? _opening;

  /// 应用数据库。首次访问时打开。
  static Future<Database> get database {
    return _opening ??= _openDefault().catchError((Object error) {
      // 打开失败不缓存，下次访问重试
      _opening = null;
      throw error;
    });
  }

  static Future<String> _defaultPath() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final profile = AppConfig.profile;
    return join(docsDir.path, profile.isEmpty ? 'whisper.db' : 'whisper-$profile.db');
  }

  static Future<Database> _openDefault() async =>
      openEncrypted(await _defaultPath(), DbKeyStore(profile: AppConfig.profile));

  /// 打开加密的数据库。
  ///
  /// - 第一次运行：生成密钥，建一个加密的新库。
  /// - 旧版本留下的未加密库：就地加密，数据保留。
  /// - 库是加密的但密钥找不到了（系统密钥环被清空或换了账号）：内容已经无法读出，
  ///   把旧文件改名为 `<名字>.unreadable-<时间>` 留在原处，另建一个新库。
  static Future<Database> openEncrypted(String path, DbKeyStore keys) async {
    final file = File(path);
    final exists = await file.exists() && await file.length() > 0;
    final plaintext = exists && await DbEncryption.isPlaintextFile(path);
    var key = await keys.load();
    if (key == null) {
      if (exists && !plaintext) {
        await file.rename('$path.unreadable-${DateTime.now().millisecondsSinceEpoch}');
        for (final suffix in const ['-wal', '-shm', '-journal']) {
          final side = File('$path$suffix');
          if (await side.exists()) await side.delete();
        }
      }
      key = await keys.create();
    }
    if (plaintext) await DbEncryption.encryptInPlace(path, key);
    return openAt(path, key: key);
  }

  /// 打开指定路径的数据库并保证表结构是最新的。给了 [key] 时按加密库打开。
  static Future<Database> openAt(String path, {bool singleInstance = true, String? key}) {
    return openDatabase(
      path,
      version: schemaVersion,
      singleInstance: singleInstance,
      onConfigure: key == null ? null : (db) => DbEncryption.applyKey(db, key),
      onCreate: (db, _) => _ensureSchema(db),
      onUpgrade: (db, _, _) => _ensureSchema(db),
    );
  }

  /// 清除全部数据：关闭并删除数据库文件，连同它的密钥。之后再访问会得到一个全新的空库。
  static Future<void> destroy() async =>
      destroyAt(await _defaultPath(), DbKeyStore(profile: AppConfig.profile));

  static Future<void> destroyAt(String path, DbKeyStore keys) async {
    await close();
    await deleteDatabase(path);
    await keys.clear();
  }

  /// 测试用：让后续访问都落到给定的数据库上。
  static void useForTesting(Database db) {
    _opening = Future.value(db);
  }

  static Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) {
      try {
        await (await opening).close();
      } catch (_) {
        // 打开本来就失败了，没有可关的
      }
    }
  }

  // 每次 execute 只放一条语句：sqflite 不保证执行同一字符串里的后续语句。
  static Future<void> _ensureSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS contacts (
        deviceId TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        x25519PublicKeyBase64 TEXT NOT NULL,
        ed25519PublicKeyBase64 TEXT NOT NULL,
        safetyCode TEXT NOT NULL,
        isVerified INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL,
        lastMessageTime INTEGER NOT NULL DEFAULT 0,
        sessionId TEXT NOT NULL DEFAULT '',
        peerRole TEXT NOT NULL DEFAULT '',
        burnAfterRead INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await _addColumnIfMissing(db, 'contacts', 'sessionId', "TEXT NOT NULL DEFAULT ''");
    await _addColumnIfMissing(db, 'contacts', 'peerRole', "TEXT NOT NULL DEFAULT ''");
    await _addColumnIfMissing(db, 'contacts', 'burnAfterRead', 'INTEGER NOT NULL DEFAULT 0');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        msgId TEXT PRIMARY KEY,
        sessionId TEXT NOT NULL,
        senderPublicKey TEXT NOT NULL,
        ciphertext TEXT NOT NULL,
        sequenceNumber INTEGER NOT NULL,
        timestamp INTEGER NOT NULL,
        direction TEXT NOT NULL,
        delivered INTEGER NOT NULL DEFAULT 0,
        read INTEGER NOT NULL DEFAULT 0,
        burnAfterRead INTEGER NOT NULL DEFAULT 0,
        readAt INTEGER,
        relayed INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await _addColumnIfMissing(db, 'messages', 'relayed', 'INTEGER NOT NULL DEFAULT 0');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS outbox (
        msgId TEXT PRIMARY KEY,
        sessionId TEXT NOT NULL,
        payload TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS invites (
        inviteId TEXT PRIMARY KEY,
        role TEXT NOT NULL,
        code TEXT NOT NULL,
        expiry INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    const indexes = {
      'idx_contacts_name': 'contacts(name)',
      'idx_contacts_lastMessageTime': 'contacts(lastMessageTime)',
      'idx_messages_session': 'messages(sessionId, timestamp)',
      'idx_messages_timestamp': 'messages(timestamp)',
      'idx_messages_delivered': 'messages(delivered)',
    };
    for (final entry in indexes.entries) {
      await db.execute('DROP INDEX IF EXISTS ${entry.key}');
      await db.execute('CREATE INDEX ${entry.key} ON ${entry.value}');
    }
  }

  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (columns.any((c) => c['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }
}
