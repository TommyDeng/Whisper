/// 还没走完的邀请：自己发出的（inviter）和自己正在加入的（joiner）。
/// 存下来是为了重启后还能接着等对方。
library;

import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

class PendingInvite {
  const PendingInvite({
    required this.inviteId,
    required this.role,
    required this.code,
    required this.expiry,
  });

  final String inviteId;

  /// `inviter` 或 `joiner`。
  final String role;

  /// 邀请码原文。
  final String code;

  /// 过期时刻，unix 秒。
  final int expiry;
}

class PendingInviteStore {
  PendingInviteStore._();

  static Future<void> save(PendingInvite invite) async {
    final db = await AppDatabase.database;
    await db.insert(
      'invites',
      {
        'inviteId': invite.inviteId,
        'role': invite.role,
        'code': invite.code,
        'expiry': invite.expiry,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> remove(String inviteId) async {
    final db = await AppDatabase.database;
    await db.delete('invites', where: 'inviteId = ?', whereArgs: [inviteId]);
  }

  /// 未过期的邀请，按过期时间升序；顺带删掉已过期的。
  static Future<List<PendingInvite>> loadActive({int? nowSeconds}) async {
    final db = await AppDatabase.database;
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.delete('invites', where: 'expiry <= ?', whereArgs: [now]);
    final rows = await db.query('invites', orderBy: 'expiry ASC');
    return rows
        .map((row) => PendingInvite(
              inviteId: row['inviteId'] as String,
              role: row['role'] as String,
              code: row['code'] as String,
              expiry: row['expiry'] as int,
            ))
        .toList();
  }
}
