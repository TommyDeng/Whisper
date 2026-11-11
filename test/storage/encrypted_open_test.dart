// AppDatabase 的加密打开：首次建库、旧明文库迁移、密钥丢失、清除全部数据。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:whisper/storage/app_database.dart';
import 'package:whisper/storage/db_encryption.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String path;
  late DbKeyStore keys;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('whisper-open-test');
    path = p.join(dir.path, 'whisper.db');
    keys = DbKeyStore();
  });

  tearDown(() async {
    await AppDatabase.close();
    await dir.delete(recursive: true);
  });

  bool fileContains(String text) =>
      latin1.decode(File(path).readAsBytesSync()).contains(latin1.decode(utf8.encode(text)));

  test('第一次打开：生成密钥，库是加密的，重开数据还在', () async {
    var db = await AppDatabase.openEncrypted(path, keys);
    await db.insert('settings', {'key': 'displayName', 'value': 'whisper-plain-marker'});
    await db.close();

    final key = await keys.load();
    expect(key, isNotNull);
    expect(await DbEncryption.isPlaintextFile(path), isFalse);
    expect(fileContains('whisper-plain-marker'), isFalse);

    db = await AppDatabase.openEncrypted(path, keys);
    expect((await db.query('settings')).single['value'], 'whisper-plain-marker');
    expect(await keys.load(), key, reason: '不会换密钥');
    await db.close();
  });

  test('旧版本的明文库就地加密，数据保留', () async {
    var db = await AppDatabase.openAt(path, singleInstance: false);
    await db.insert('settings', {'key': 'displayName', 'value': 'whisper-plain-marker'});
    await db.close();
    expect(fileContains('whisper-plain-marker'), isTrue);

    db = await AppDatabase.openEncrypted(path, keys);
    expect((await db.query('settings')).single['value'], 'whisper-plain-marker');
    await db.close();
    expect(await DbEncryption.isPlaintextFile(path), isFalse);
    expect(fileContains('whisper-plain-marker'), isFalse);
  });

  test('密钥丢了：旧文件改名留着，另建一个空的新库', () async {
    var db = await AppDatabase.openEncrypted(path, keys);
    await db.insert('settings', {'key': 'displayName', 'value': 'x'});
    await db.close();
    await keys.clear();

    db = await AppDatabase.openEncrypted(path, keys);
    expect(await db.query('settings'), isEmpty);
    await db.close();
    final names = dir.listSync().map((e) => p.basename(e.path)).toList();
    expect(names.where((n) => n.startsWith('whisper.db.unreadable-')), hasLength(1));
  });

  test('destroyAt 删掉库文件和密钥，之后是一个全新的库', () async {
    final db = await AppDatabase.openEncrypted(path, keys);
    AppDatabase.useForTesting(db);
    await db.insert('settings', {'key': 'displayName', 'value': 'x'});
    final oldKey = await keys.load();

    await AppDatabase.destroyAt(path, keys);
    expect(File(path).existsSync(), isFalse);
    expect(await keys.load(), isNull);

    final fresh = await AppDatabase.openEncrypted(path, keys);
    expect(await fresh.query('settings'), isEmpty);
    expect(await keys.load(), isNot(oldKey));
    await fresh.close();
  });
}
