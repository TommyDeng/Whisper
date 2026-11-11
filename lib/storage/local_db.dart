/// 耳语本地加密存储。
///
/// 聊天历史已在客户端 E2EE 加密，数据库文件本身不额外加密。
/// 提供：
/// - 消息插入/查询/更新/删除
/// - 7 天自动删除旧消息
/// - 阅后即焚：读取后删除

import 'package:sqflite/sqflite.dart';

import '../e2ee/message.dart';
import 'app_database.dart';

/// 消息表的读写。数据库本身由 [AppDatabase] 打开和建表。
class LocalDatabase {
  static Future<Database> get database => AppDatabase.database;

  /// 插入一条消息（已存在则替换）
  static Future<void> insertMessage(StoredMessage msg) async {
    final db = await database;
    await db.insert(
      'messages',
      msg.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 插入一条消息；msgId 已存在时什么都不做并返回 false。
  /// 收到的消息用它去重：中继在确认之前会重复投递同一条。
  static Future<bool> insertMessageIfAbsent(StoredMessage msg) async {
    final db = await database;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'messages',
        columns: ['msgId'],
        where: 'msgId = ?',
        whereArgs: [msg.msgId],
        limit: 1,
      );
      if (existing.isNotEmpty) return false;
      await txn.insert('messages', msg.toMap());
      return true;
    });
  }

  /// 根据 msgId 查询一条消息
  static Future<StoredMessage?> getMessage(String msgId) async {
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'msgId = ?',
      whereArgs: [msgId],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return StoredMessage.fromMap(results.first);
  }

  /// 查询指定会话的所有消息（按时间升序）
  static Future<List<StoredMessage>> getSessionMessages(
    String sessionId, {
    int? limit,
  }) async {
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'sessionId = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp ASC, rowid ASC',
      limit: limit,
    );
    return results.map((m) => StoredMessage.fromMap(m)).toList();
  }

  /// 标记消息为已送达（对方 ACK）
  static Future<void> markDelivered(String msgId) async {
    final db = await database;
    await db.update(
      'messages',
      {'delivered': 1},
      where: 'msgId = ?',
      whereArgs: [msgId],
    );
  }

  /// 标记消息已被中继收下（`stored`）
  static Future<void> markRelayed(String msgId) async {
    final db = await database;
    await db.update(
      'messages',
      {'relayed': 1},
      where: 'msgId = ?',
      whereArgs: [msgId],
    );
  }

  /// 某个会话里自己发出、但中继还没确认收下的消息（重启后需要重发）
  static Future<List<StoredMessage>> getUnrelayedMessages(String sessionId) async {
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'sessionId = ? AND direction = ? AND relayed = 0 AND delivered = 0',
      whereArgs: [sessionId, 'sent'],
      orderBy: 'timestamp ASC, rowid ASC',
    );
    return results.map((m) => StoredMessage.fromMap(m)).toList();
  }

  /// 删除一个会话的全部消息
  static Future<int> deleteSessionMessages(String sessionId) async {
    final db = await database;
    return db.delete('messages', where: 'sessionId = ?', whereArgs: [sessionId]);
  }

  /// 标记消息为已读
  static Future<void> markRead(String msgId) async {
    final db = await database;
    await db.update(
      'messages',
      {'read': 1, 'readAt': DateTime.now().millisecondsSinceEpoch},
      where: 'msgId = ?',
      whereArgs: [msgId],
    );
  }

  /// 删除一条消息
  static Future<void> deleteMessage(String msgId) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'msgId = ?',
      whereArgs: [msgId],
    );
  }

  /// 7 天自动删除旧消息（非阅后即焚的消息）
  static Future<int> purgeExpiredMessages({int retentionDays = 7}) async {
    final db = await database;
    final cutoff =
        DateTime.now().subtract(Duration(days: retentionDays)).millisecondsSinceEpoch;
    return await db.delete(
      'messages',
      where: 'timestamp < ? AND burnAfterRead = 0',
      whereArgs: [cutoff],
    );
  }

  /// 处理阅后即焚：如果消息开启 burnAfterRead 且已读，则删除
  static Future<void> handleBurnAfterRead(StoredMessage msg) async {
    if (msg.burnAfterRead && msg.read) {
      await deleteMessage(msg.msgId);
    }
  }

  /// 获取所有未送达的消息（用于重传）
  static Future<List<StoredMessage>> getUndeliveredMessages() async {
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'delivered = 0 AND direction = ?',
      whereArgs: ['sent'],
      orderBy: 'timestamp ASC',
    );
    return results.map((m) => StoredMessage.fromMap(m)).toList();
  }

  /// 关闭数据库
  static Future<void> close() => AppDatabase.close();
}
