/// 消息表和待发回执表的读写。
///
/// 消息正文以端到端加密的密文存放；数据库文件本身另有整库加密（见 db_encryption.dart）。
library;

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

  /// 某个会话里收到的、还没读的消息：`msgId` 和 `burnAfterRead`。
  static Future<List<({String msgId, bool burn})>> getUnreadReceived(String sessionId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      columns: ['msgId', 'burnAfterRead'],
      where: 'sessionId = ? AND direction = ? AND read = 0',
      whereArgs: [sessionId, 'received'],
      orderBy: 'timestamp ASC, rowid ASC',
    );
    return [
      for (final row in rows)
        (msgId: row['msgId'] as String, burn: (row['burnAfterRead'] as int) != 0),
    ];
  }

  /// 把 [msgIds] 标为已读，并在同一个事务里写入要发给对方的回执 [receipts]。
  /// 两件事要么都发生要么都不发生：否则中途崩溃会让对方永远收不到已读回执。
  static Future<void> markReadWithReceipts({
    required String sessionId,
    required List<String> msgIds,
    required List<({String msgId, String payload})> receipts,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      for (final chunk in _chunks(msgIds)) {
        await txn.update(
          'messages',
          {'read': 1, 'readAt': now},
          where: 'sessionId = ? AND direction = ? AND read = 0 AND msgId IN (${_marks(chunk)})',
          whereArgs: [sessionId, 'received', ...chunk],
        );
      }
      for (final receipt in receipts) {
        await txn.insert(
          'outbox',
          {'msgId': receipt.msgId, 'sessionId': sessionId, 'payload': receipt.payload, 'createdAt': now},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// 应用对方发来的回执：[msgIds] 里属于 [sessionId]、自己发出的消息标为已送达；
  /// [deleteBurned] 为 true 时其中阅后即焚的直接删除。返回被删除的 msgId。
  static Future<List<String>> applyReceipt({
    required String sessionId,
    required List<String> msgIds,
    required bool deleteBurned,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final deleted = <String>[];
      for (final chunk in _chunks(msgIds)) {
        final scope = 'sessionId = ? AND direction = ? AND msgId IN (${_marks(chunk)})';
        final args = [sessionId, 'sent', ...chunk];
        await txn.update('messages', {'delivered': 1}, where: scope, whereArgs: args);
        if (!deleteBurned) continue;
        final burned = await txn.query(
          'messages',
          columns: ['msgId'],
          where: '$scope AND burnAfterRead = 1',
          whereArgs: args,
        );
        deleted.addAll(burned.map((row) => row['msgId'] as String));
        await txn.delete('messages', where: '$scope AND burnAfterRead = 1', whereArgs: args);
      }
      return deleted;
    });
  }

  static Iterable<List<String>> _chunks(List<String> ids) sync* {
    for (var i = 0; i < ids.length; i += 500) {
      yield ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
    }
  }

  static String _marks(List<String> ids) => List.filled(ids.length, '?').join(',');

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

  /// 插入一条待发回执到 outbox
  static Future<void> insertOutbox({
    required String msgId,
    required String sessionId,
    required String payload,
    required int createdAt,
  }) async {
    final db = await database;
    await db.insert(
      'outbox',
      {
        'msgId': msgId,
        'sessionId': sessionId,
        'payload': payload,
        'createdAt': createdAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 按 id 删除 outbox 记录
  static Future<int> deleteOutbox(String msgId) async {
    final db = await database;
    return db.delete('outbox', where: 'msgId = ?', whereArgs: [msgId]);
  }

  /// 查询某个会话的全部待发回执，按 createdAt, rowid 升序
  static Future<List<Map<String, dynamic>>> queryOutbox(String sessionId) async {
    final db = await database;
    final results = await db.query(
      'outbox',
      where: 'sessionId = ?',
      whereArgs: [sessionId],
      orderBy: 'createdAt ASC, rowid ASC',
    );
    return results;
  }

  /// 删除某个会话的全部 outbox 记录
  static Future<int> deleteOutboxForSession(String sessionId) async {
    final db = await database;
    return db.delete('outbox', where: 'sessionId = ?', whereArgs: [sessionId]);
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

  /// 删除早于 [cutoff]（unix 毫秒）的消息（包括没读的和阅后即焚的）以及同样旧的待发回执。
  /// 返回被删除消息的 msgId 和 sessionId。
  static Future<List<({String msgId, String sessionId})>> purgeExpired(int cutoff) async {
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        columns: ['msgId', 'sessionId'],
        where: 'timestamp < ?',
        whereArgs: [cutoff],
      );
      await txn.delete('messages', where: 'timestamp < ?', whereArgs: [cutoff]);
      await txn.delete('outbox', where: 'createdAt < ?', whereArgs: [cutoff]);
      return [
        for (final row in rows)
          (msgId: row['msgId'] as String, sessionId: row['sessionId'] as String),
      ];
    });
  }

  /// 重新配对后把旧会话的消息搬到新会话：[rewritten] 是用新会话重新加密过的密文，
  /// 不在其中的旧消息（解不开的）连同旧会话的待发回执一起删除。
  /// 对方还没确认送达的消息重置为“中继未收下”，由新会话重发（msgId 不变，对方会去重）。
  static Future<void> moveSessionMessages({
    required String fromSessionId,
    required String toSessionId,
    required Map<String, String> rewritten,
    required String peerPublicKey,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final entry in rewritten.entries) {
        await txn.update(
          'messages',
          {'sessionId': toSessionId, 'ciphertext': entry.value},
          where: 'msgId = ? AND sessionId = ?',
          whereArgs: [entry.key, fromSessionId],
        );
      }
      await txn.delete('messages', where: 'sessionId = ?', whereArgs: [fromSessionId]);
      await txn.delete('outbox', where: 'sessionId = ?', whereArgs: [fromSessionId]);
      await txn.update(
        'messages',
        {'relayed': 0},
        where: 'sessionId = ? AND direction = ? AND delivered = 0',
        whereArgs: [toSessionId, 'sent'],
      );
      await txn.update(
        'messages',
        {'senderPublicKey': peerPublicKey},
        where: 'sessionId = ? AND direction = ?',
        whereArgs: [toSessionId, 'received'],
      );
    });
  }

  /// 删除已读的、收到的阅后即焚消息。
  /// [sessionId] 为 null 时处理所有会话。返回被删除消息的 (msgId, sessionId) 列表。
  static Future<List<Map<String, dynamic>>> deleteReadBurned({String? sessionId}) async {
    final db = await database;
    final clauses = <String>[];
    final whereArgs = <Object?>[];
    clauses.add('direction = ?');
    whereArgs.add('received');
    clauses.add('burnAfterRead = 1');
    clauses.add('read = 1');
    if (sessionId != null) {
      clauses.add('sessionId = ?');
      whereArgs.add(sessionId);
    }
    final affected = await db.query(
      'messages',
      columns: ['msgId', 'sessionId'],
      where: clauses.join(' AND '),
      whereArgs: whereArgs,
    );
    await db.delete(
      'messages',
      where: clauses.join(' AND '),
      whereArgs: whereArgs,
    );
    return affected.cast<Map<String, dynamic>>();
  }

  /// 记下一条文件消息对应的本地文件路径（发出的是源文件，收到的是保存位置）。
  /// 消息已经不在了（刚好被删）时不记。
  static Future<void> setFilePath(String msgId, String localPath) async {
    final db = await database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO file_transfers (msgId, localPath, updatedAt) '
      'SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM messages WHERE msgId = ?)',
      [msgId, localPath, DateTime.now().millisecondsSinceEpoch, msgId],
    );
  }

  /// 一个会话里各条文件消息的本地文件路径：msgId → 路径。
  static Future<Map<String, String>> getFilePaths(String sessionId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT f.msgId, f.localPath FROM file_transfers f '
      'JOIN messages m ON m.msgId = f.msgId WHERE m.sessionId = ?',
      [sessionId],
    );
    return {
      for (final row in rows) row['msgId'] as String: row['localPath'] as String,
    };
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
