/// 耳语 Whisper - 联系人本地存储
///
/// 基于 SQLite 存储已配对的亲友身份。

import 'package:sqflite/sqflite.dart';

import '../contact/contact_model.dart';
import '../storage/app_database.dart';

/// 联系人表的读写。数据库本身由 [AppDatabase] 打开和建表。
class ContactStore {
  static Future<Database> get database => AppDatabase.database;

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

  /// 开启或关闭这个会话的阅后即焚
  static Future<void> updateContactBurnAfterRead(String deviceId, bool enabled) async {
    final db = await database;
    await db.update(
      'contacts',
      {'burnAfterRead': enabled ? 1 : 0},
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
  static Future<void> close() => AppDatabase.close();
}
