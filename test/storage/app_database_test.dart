import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:whisper/contact/contact.dart';
import 'package:whisper/e2ee/message.dart';
import 'package:whisper/storage/storage.dart';

Contact _contact({String sessionId = 'S', String peerRole = 'a'}) => Contact(
      deviceId: 'dev-1',
      name: '小明',
      x25519PublicKeyBase64: 'x',
      ed25519PublicKeyBase64: 'e',
      safetyCode: 'code',
      isVerified: false,
      createdAt: 1,
      lastMessageTime: 2,
      sessionId: sessionId,
      peerRole: peerRole,
    );

StoredMessage _message(String id, {String direction = 'sent', int timestamp = 10}) => StoredMessage(
      msgId: id,
      sessionId: 'S',
      senderPublicKey: 'x',
      ciphertext: 'ct-$id',
      sequenceNumber: 0,
      timestamp: timestamp,
      direction: direction,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('新建的数据库', () {
    setUp(() async {
      AppDatabase.useForTesting(
        await AppDatabase.openAt(inMemoryDatabasePath, singleInstance: false),
      );
    });
    tearDown(AppDatabase.close);

    test('联系人和消息共用一个库，两张表都在', () async {
      await ContactStore.upsertContact(_contact());
      await LocalDatabase.insertMessage(_message('m1'));

      final contact = (await ContactStore.getAllContacts()).single;
      expect(contact.sessionId, 'S');
      expect(contact.peerRole, 'a');
      expect(contact.remoteRole, 'b');
      expect(contact.hasSession, isTrue);
      expect((await LocalDatabase.getSessionMessages('S')).single.msgId, 'm1');
    });

    test('insertMessageIfAbsent 按 msgId 去重，不覆盖已有内容', () async {
      expect(await LocalDatabase.insertMessageIfAbsent(_message('m1')), isTrue);
      final again = StoredMessage(
        msgId: 'm1',
        sessionId: 'S',
        senderPublicKey: 'x',
        ciphertext: 'other',
        sequenceNumber: 0,
        timestamp: 99,
        direction: 'received',
      );
      expect(await LocalDatabase.insertMessageIfAbsent(again), isFalse);
      expect((await LocalDatabase.getMessage('m1'))!.ciphertext, 'ct-m1');
    });

    test('未被中继确认的已发消息可以查出来，确认后不再出现', () async {
      await LocalDatabase.insertMessage(_message('m1', timestamp: 1));
      await LocalDatabase.insertMessage(_message('m2', timestamp: 2));
      await LocalDatabase.insertMessage(_message('m3', direction: 'received', timestamp: 3));
      expect((await LocalDatabase.getUnrelayedMessages('S')).map((m) => m.msgId), ['m1', 'm2']);

      await LocalDatabase.markRelayed('m1');
      await LocalDatabase.markDelivered('m2');
      expect(await LocalDatabase.getUnrelayedMessages('S'), isEmpty);
      expect((await LocalDatabase.getMessage('m1'))!.relayed, isTrue);
      expect((await LocalDatabase.getMessage('m2'))!.delivered, isTrue);
    });

    test('删除会话的全部消息', () async {
      await LocalDatabase.insertMessage(_message('m1'));
      await LocalDatabase.insertMessage(_message('m2'));
      expect(await LocalDatabase.deleteSessionMessages('S'), 2);
      expect(await LocalDatabase.getSessionMessages('S'), isEmpty);
    });

    test('待完成的邀请：保存、读取、过期清理、删除', () async {
      await PendingInviteStore.save(
        const PendingInvite(inviteId: 'i1', role: 'inviter', code: 'C1', expiry: 2000),
      );
      await PendingInviteStore.save(
        const PendingInvite(inviteId: 'i2', role: 'joiner', code: 'C2', expiry: 1000),
      );
      expect((await PendingInviteStore.loadActive(nowSeconds: 500)).map((i) => i.inviteId), ['i2', 'i1']);
      expect((await PendingInviteStore.loadActive(nowSeconds: 1000)).map((i) => i.inviteId), ['i1']);
      await PendingInviteStore.remove('i1');
      expect(await PendingInviteStore.loadActive(nowSeconds: 500), isEmpty);
    });

    test('联系人的阅后即焚开关默认关，可以打开再关上', () async {
      const contact = Contact(
        deviceId: 'burn',
        name: '小焚',
        x25519PublicKeyBase64: 'x',
        ed25519PublicKeyBase64: 'e',
        safetyCode: 'code',
        isVerified: false,
        createdAt: 1,
        lastMessageTime: 0,
      );
      await ContactStore.upsertContact(contact);
      expect((await ContactStore.getContact('burn'))!.burnAfterRead, isFalse);
      await ContactStore.updateContactBurnAfterRead('burn', true);
      expect((await ContactStore.getContact('burn'))!.burnAfterRead, isTrue);
      expect(contact.copyWith(burnAfterRead: true).burnAfterRead, isTrue);
      await ContactStore.updateContactBurnAfterRead('burn', false);
      expect((await ContactStore.getContact('burn'))!.burnAfterRead, isFalse);
    });

    test('设置读写', () async {
      expect(await SettingsStore.get(SettingsStore.displayName), isNull);
      await SettingsStore.set(SettingsStore.displayName, '小红');
      await SettingsStore.set(SettingsStore.displayName, '小蓝');
      expect(await SettingsStore.get(SettingsStore.displayName), '小蓝');
    });
  });

  test('旧版数据库（只有联系人表、没有会话字段）升级后数据保留、表补齐', () async {
    final dir = await Directory.systemTemp.createTemp('whisper-db-test');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'whisper.db');

    final old = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) => db.execute('''
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
      '''),
    );
    await old.insert('contacts', {
      'deviceId': 'old',
      'name': '旧联系人',
      'x25519PublicKeyBase64': 'x',
      'ed25519PublicKeyBase64': '',
      'safetyCode': '',
      'createdAt': 1,
    });
    await old.close();

    AppDatabase.useForTesting(await AppDatabase.openAt(path));
    addTearDown(AppDatabase.close);

    final contact = (await ContactStore.getAllContacts()).single;
    expect(contact.name, '旧联系人');
    expect(contact.sessionId, '');
    expect(contact.hasSession, isFalse);

    await LocalDatabase.insertMessage(_message('m1'));
    expect((await LocalDatabase.getSessionMessages('S')).single.relayed, isFalse);
    await SettingsStore.set('k', 'v');
    expect(await PendingInviteStore.loadActive(), isEmpty);
  });
}
