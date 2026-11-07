/// 耳语本地加密存储。
///
/// 聊天历史已在客户端 E2EE 加密，数据库文件本身不额外加密。
/// 提供：
/// - 消息插入/查询/更新/删除
/// - 7 天自动删除旧消息
/// - 阅后即焚：读取后删除

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../e2ee/message.dart';

/// 本地数据库管理器（单例）
class LocalDatabase {
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
          CREATE TABLE messages (
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
            readAt INTEGER
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_messages_session ON messages(sessionId);
          CREATE INDEX idx_messages_timestamp ON messages(timestamp);
          CREATE INDEX idx_messages_delivered ON messages(delivered);
        ''');
      },
    );
  }

  /// 插入一条消息（已存在则替换）
  static Future<void> insertMessage(StoredMessage msg) async {
    final db = await database;
    await db.insert(
      'messages',
      msg.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
      orderBy: 'timestamp ASC',
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
  static Future<void> close() async {
    final db = _db;
    if (db != null) {
      await db.close();
      _db = null;
    }
  }
}
