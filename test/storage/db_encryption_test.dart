import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:whisper/storage/db_encryption.dart';

void main() {
  late Directory dir;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('whisper-enc-test');
    path = p.join(dir.path, 'whisper.db');
  });

  tearDown(() => dir.delete(recursive: true));

  Future<Database> open(String? key) => openDatabase(
        path,
        singleInstance: false,
        onConfigure: key == null ? null : (db) => DbEncryption.applyKey(db, key),
      );

  bool fileContains(String text) {
    final bytes = File(path).readAsBytesSync();
    return latin1.decode(bytes).contains(latin1.decode(utf8.encode(text)));
  }

  test('密钥是 64 位小写十六进制，每次不同', () {
    final a = DbEncryption.newKey();
    final b = DbEncryption.newKey();
    expect(DbEncryption.isValidKey(a), isTrue);
    expect(a, isNot(b));
    expect(DbEncryption.isValidKey("x' OR 1=1 --"), isFalse);
    expect(DbEncryption.isValidKey('A' * 64), isFalse);
    expect(DbEncryption.isValidKey('a' * 63), isFalse);
  });

  test('带密钥创建的库：文件里没有明文，没有密钥或密钥不对都打不开', () async {
    final key = DbEncryption.newKey();
    var db = await open(key);
    await db.execute('CREATE TABLE t (name TEXT)');
    await db.insert('t', {'name': 'whisper-secret-联系人'});
    await db.close();

    expect(await DbEncryption.isPlaintextFile(path), isFalse);
    expect(fileContains('SQLite format 3'), isFalse);
    expect(fileContains('whisper-secret-联系人'), isFalse);

    db = await open(key);
    expect((await db.query('t')).single['name'], 'whisper-secret-联系人');
    await db.close();

    Future<void> mustFail(String? k) async {
      Database? opened;
      try {
        opened = await open(k);
        await opened.query('t');
        fail('不该读得出来');
      } on DatabaseException catch (_) {
        // 预期
      } finally {
        await opened?.close();
      }
    }

    await mustFail(null);
    await mustFail(DbEncryption.newKey());
  });

  test('旧的明文库可以就地加密，数据保留', () async {
    var db = await open(null);
    await db.execute('CREATE TABLE t (name TEXT)');
    await db.insert('t', {'name': 'whisper-secret-联系人'});
    await db.close();
    expect(await DbEncryption.isPlaintextFile(path), isTrue);
    expect(fileContains('whisper-secret-联系人'), isTrue);

    final key = DbEncryption.newKey();
    await DbEncryption.encryptInPlace(path, key);
    expect(await DbEncryption.isPlaintextFile(path), isFalse);
    expect(fileContains('whisper-secret-联系人'), isFalse);

    db = await open(key);
    expect((await db.query('t')).single['name'], 'whisper-secret-联系人');
    await db.close();
  });

  test('不存在的文件不算明文库；不合法的密钥被拒绝', () async {
    expect(await DbEncryption.isPlaintextFile(path), isFalse);
    await expectLater(DbEncryption.encryptInPlace(path, 'abc'), throwsArgumentError);
  });
}
