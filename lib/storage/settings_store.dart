/// 简单的键值设置。
library;

import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

class SettingsStore {
  SettingsStore._();

  /// 配对时告诉对方的称呼。
  static const String displayName = 'displayName';

  static Future<String?> get(String key) async {
    final db = await AppDatabase.database;
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  static Future<void> set(String key, String value) async {
    final db = await AppDatabase.database;
    await db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
