/// 耳语 Whisper - 联系人本地存储
///
/// 基于 SQLite 存储已配对的亲友身份。

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../contact/contact_model.dart';

/// 联系人数据库管理器（单例）
class ContactStore {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dbPath = join(docsDir.path, 'whisper.db');
    return await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE contacts (
            deviceId TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            x25519PublicKeyBase64 TEXT NOT NULL,
            ed25519PublicKeyBase64 TEXT NOT NULL,
            safetyCode TEXT NOT NULL,
            isVerified INTEGER NOT NULL DEFAULT 0,
            createdAt INTEGER NOT NULL,
            lastMessageTime INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_contacts_name ON contacts(name);
          CREATE INDEX idx_contacts_lastMessageTime ON contacts(lastMessageTime);
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // 未来版本升级时在此处理
      },
    );
  }

  /// 插入或更新联系人
  static Future<void> upsertContact(Contact contact) async {
    final db = await database;
    await db.insert(
      'contacts',
      contact.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 根据 deviceId 查询联系人
  static Future<Contact?> getContact(String deviceId) async {
    final db = await database;
    final results = await db.query(
      'contacts',
      where: 'deviceId = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return Contact.fromMap(results.first);
  }

  /// 查询所有联系人，按最后消息时间降序
  static Future<List<Contact>> getAllContacts() async {
    final db = await database;
    final results = await db.query(
      'contacts',
      orderBy: 'lastMessageTime DESC, createdAt DESC',
    );
    return results.map((m) => Contact.fromMap(m)).toList();
  }

  /// 更新联系人名称
  static Future<void> updateContactName(String deviceId, String name) async {
    final db = await database;
    await db.update(
      'contacts',
      {'name': name},
      where: 'deviceId = ?',
      whereArgs: [deviceId],
    );
  }

  /// 更新联系人验证状态
  static Future<void> updateContactVerification(String deviceId, bool isVerified) async {
    final db = await database;
    await db.update(
      'contacts',
      {'isVerified': isVerified ? 1 : 0},
      where: 'deviceId = ?',
      whereArgs: [deviceId],
    );
  }

  /// 更新联系人最后消息时间
  static Future<void> updateContactLastMessageTime(String deviceId, int time) async {
    final db = await database;
    await db.update(
      'contacts',
      {'lastMessageTime': time},
      where: 'deviceId = ?',
      whereArgs: [deviceId],
    );
  }

  /// 删除联系人
  static Future<void> deleteContact(String deviceId) async {
    final db = await database;
    await db.delete(
      'contacts',
      where: 'deviceId = ?',
      whereArgs: [deviceId],
    );
  }

  /// 关闭数据库
  static Future<void> close() async {
    final db = _db;
    if (db != null) {
      await db.close();
      _db = null;
    }
  }
}
