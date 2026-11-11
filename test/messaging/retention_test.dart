// 本地保留策略：7 天自动删除、重新配对后保留旧记录、清空时的内存状态，以及回执的边界情况。
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:whisper/contact/contact.dart';
import 'package:whisper/e2ee/message.dart';
import 'package:whisper/identity/identity_store.dart';
import 'package:whisper/messaging/message_codec.dart';
import 'package:whisper/messaging/messaging_service.dart';
import 'package:whisper/storage/storage.dart';

import '../relay/fake_relay.dart';

const _oldSession = 'session-0000000000000000000001';
const _newSession = 'session-0000000000000000000002';
const _day = Duration(days: 1);

Future<void> _until(bool Function() condition, {String what = '条件'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 60));

void main() {
  late IdentityKeyPair alice;
  late IdentityKeyPair bob;
  late Contact bobContact; // Alice 眼里的 Bob；旧会话里 Alice 是 a
  late FakeRelay relay;
  late MessagingService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Contact contactFor(String sessionId, String myRole) => Contact(
        deviceId: 'bob',
        name: 'Bob',
        x25519PublicKeyBase64: bob.x25519PublicKeyBase64,
        ed25519PublicKeyBase64: bob.ed25519PublicKeyBase64,
        safetyCode: 'code',
        isVerified: false,
        createdAt: 1,
        lastMessageTime: 0,
        sessionId: sessionId,
        peerRole: myRole,
      );

  Future<SecretKey> bobKeyFor(String sessionId) => MessageCodec.deriveKey(
        myPrivateKey: bob.x25519PrivateKey,
        peerPublicKey: alice.x25519PublicKey,
        sessionId: sessionId,
      );

  /// Bob 在 [contact] 这个会话里加密一条内容。
  Future<String> fromBob(Contact contact, String id, ChatContent content) async => MessageCodec.seal(
        key: await bobKeyFor(contact.sessionId),
        sessionId: contact.sessionId,
        senderRole: contact.remoteRole,
        messageId: id,
        content: content,
      );

  /// 直接往库里放一条 Bob 发来的消息。
  Future<void> storeReceived(Contact contact, String id, String text, {required int ts, bool burn = false}) async {
    await LocalDatabase.insertMessage(StoredMessage(
      msgId: id,
      sessionId: contact.sessionId,
      senderPublicKey: contact.x25519PublicKeyBase64,
      ciphertext: await fromBob(contact, id, ChatContent.text(text, sentAt: ts, burn: burn)),
      sequenceNumber: 0,
      timestamp: ts,
      direction: 'received',
      burnAfterRead: burn,
    ));
  }

  Future<FakeConnection> welcome() async {
    await _until(() => relay.connections.isNotEmpty, what: '连接');
    final connection = relay.last;
    connection.push({'type': 'welcome', 'peer': 'a', 'peerOnline': false});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return connection;
  }

  setUp(() async {
    AppDatabase.useForTesting(await AppDatabase.openAt(inMemoryDatabasePath, singleInstance: false));
    alice = await generateIdentityKeyPair();
    bob = await generateIdentityKeyPair();
    bobContact = contactFor(_oldSession, 'a');
    await ContactStore.upsertContact(bobContact);
    relay = FakeRelay();
    service = MessagingService(
      baseUri: Uri.parse('ws://relay.test'),
      connector: relay.connect,
      identity: () async => alice,
      backoff: const [Duration(milliseconds: 10)],
    );
  });

  tearDown(() async {
    await service.dispose();
    await AppDatabase.close();
  });

  group('回执的边界情况', () {
    test('不认识的回执种类不改任何消息的状态', () async {
      await service.start();
      final connection = await welcome();
      await service.sendText(bobContact, '你好');
      final id = connection.sentOfType('msg').single['id'] as String;

      // 编码器不产出未知种类，手工封一条
      final json = utf8.encode(jsonEncode({'t': 'receipt', 'body': '', 'ts': 1, 'kind': 'seen', 'ids': [id]}));
      final padded = Uint8List(1024);
      ByteData.sublistView(padded).setUint32(0, json.length);
      padded.setRange(4, 4 + json.length, json);
      final aead = Xchacha20.poly1305Aead();
      final box = await aead.encrypt(
        padded,
        secretKey: await bobKeyFor(_oldSession),
        nonce: aead.newNonce(),
        aad: utf8.encode('whisper/msg/v1\n$_oldSession\nb\nr-1'),
      );
      String enc(List<int> b) => base64Url.encode(b).replaceAll('=', '');
      final payload =
          jsonEncode({'v': 1, 'nonce': enc(box.nonce), 'ct': enc(box.cipherText), 'mac': enc(box.mac.bytes)});

      connection.push({'type': 'msg', 'id': 'r-1', 'payload': payload, 'ts': 2});
      await _until(() => connection.sentOfType('ack').any((f) => f['id'] == 'r-1'), what: 'ack');
      await _settle();
      expect((await LocalDatabase.getMessage(id))!.delivered, isFalse);
    });

    test('标已读和写待发回执是一起落库的', () async {
      await storeReceived(bobContact, 'burn-1', '秘密', ts: 10, burn: true);
      await storeReceived(bobContact, 'plain-1', '普通', ts: 11);
      // 没有 start：会话没连着
      await service.markRead(bobContact);
      expect((await LocalDatabase.getMessage('burn-1'))!.read, isTrue);
      expect((await LocalDatabase.getMessage('plain-1'))!.read, isTrue);
      expect(await LocalDatabase.queryOutbox(_oldSession), hasLength(1));
      // 再调一次不会多出回执
      await service.markRead(bobContact);
      expect(await LocalDatabase.queryOutbox(_oldSession), hasLength(1));
    });
  });

  group('7 天自动删除', () {
    test('超过保留期的消息全部删除，包括没读的和阅后即焚的；没到期的留着', () async {
      final now = DateTime.fromMillisecondsSinceEpoch(100 * _day.inMilliseconds);
      int daysAgo(int days, [int extraMs = 0]) => now.subtract(_day * days).millisecondsSinceEpoch + extraMs;

      await storeReceived(bobContact, 'old-plain', 'a', ts: daysAgo(8));
      await storeReceived(bobContact, 'old-burn', 'b', ts: daysAgo(7, -1), burn: true);
      await storeReceived(bobContact, 'edge', 'c', ts: daysAgo(7));
      await storeReceived(bobContact, 'fresh', 'd', ts: daysAgo(1));
      await LocalDatabase.insertOutbox(msgId: 'r-old', sessionId: _oldSession, payload: 'x', createdAt: daysAgo(9));
      await LocalDatabase.insertOutbox(msgId: 'r-new', sessionId: _oldSession, payload: 'x', createdAt: daysAgo(1));

      // 先读一遍，让明文进缓存
      expect((await service.messages(bobContact)).map((m) => m.text), ['a', 'b', 'c', 'd']);
      final notified = <String>[];
      final sub = service.updates.listen(notified.add);

      expect(await service.purgeExpired(now: now), 2);
      await _settle();
      await sub.cancel();

      expect((await service.messages(bobContact)).map((m) => m.id), ['edge', 'fresh']);
      expect((await LocalDatabase.queryOutbox(_oldSession)).map((r) => r['msgId']), ['r-new']);
      expect(notified, [_oldSession]);
    });

    test('没有到期的消息时什么都不做', () async {
      await storeReceived(bobContact, 'fresh', 'd', ts: DateTime.now().millisecondsSinceEpoch);
      expect(await service.purgeExpired(), 0);
      expect(await service.messages(bobContact), hasLength(1));
    });
  });

  group('重新配对后保留旧记录', () {
    test('旧会话的消息搬到新会话下，正文、方向、时间、焚毁标记都不变', () async {
      await service.start();
      final connection = await welcome();
      await service.sendText(bobContact, '我发的');
      final sentId = connection.sentOfType('msg').single['id'] as String;
      connection.push({'type': 'stored', 'id': sentId});
      await storeReceived(bobContact, 'in-1', '他发的', ts: 5, burn: true);
      await LocalDatabase.insertOutbox(msgId: 'r-1', sessionId: _oldSession, payload: 'x', createdAt: 1);
      await _settle();

      // 新会话里角色也换了：Alice 变成 b
      final renewed = contactFor(_newSession, 'b');
      await service.detach(bobContact);
      expect(await service.adopt(bobContact, renewed), 2);
      await ContactStore.upsertContact(renewed);

      expect(await LocalDatabase.getSessionMessages(_oldSession), isEmpty);
      expect(await LocalDatabase.queryOutbox(_oldSession), isEmpty, reason: '旧会话的回执已经发不出去');

      // 换一个实例读，确认不是靠内存里的明文缓存
      await service.dispose();
      relay = FakeRelay();
      service = MessagingService(
        baseUri: Uri.parse('ws://relay.test'),
        connector: relay.connect,
        identity: () async => alice,
        backoff: const [Duration(milliseconds: 10)],
      );
      final messages = await service.messages(renewed);
      expect(messages.map((m) => m.text), ['他发的', '我发的']);
      expect(messages.map((m) => m.isSent), [false, true]);
      expect(messages.first.burn, isTrue);
      expect(messages.first.timestamp, 5);
      expect(messages.last.id, sentId);

      // Bob 用新会话的密钥也能解开重新加密过的那条（Alice 现在是 b）
      final stored = (await LocalDatabase.getMessage(sentId))!;
      final content = await MessageCodec.open(
        key: await bobKeyFor(_newSession),
        sessionId: _newSession,
        senderRole: 'b',
        messageId: sentId,
        payload: stored.ciphertext,
      );
      expect(content.body, '我发的');
    });

    test('对方还没确认送达的消息由新会话重发，msgId 不变', () async {
      await service.start();
      final connection = await welcome();
      await service.sendText(bobContact, '还没送到');
      final sentId = connection.sentOfType('msg').single['id'] as String;
      connection.push({'type': 'stored', 'id': sentId});
      await _settle();
      expect((await LocalDatabase.getMessage(sentId))!.relayed, isTrue);

      final renewed = contactFor(_newSession, 'b');
      await service.detach(bobContact);
      await service.adopt(bobContact, renewed);
      await ContactStore.upsertContact(renewed);
      await service.attach(renewed);
      await _until(() => relay.connections.length == 2, what: '新会话的连接');
      relay.last.push({'type': 'welcome', 'peer': 'b', 'peerOnline': false});
      await _until(() => relay.last.sentOfType('msg').isNotEmpty, what: '重发');

      final frame = relay.last.sentOfType('msg').single;
      expect(frame['id'], sentId);
      final content = await MessageCodec.open(
        key: await bobKeyFor(_newSession),
        sessionId: _newSession,
        senderRole: 'b',
        messageId: sentId,
        payload: frame['payload'] as String,
      );
      expect(content.body, '还没送到');
    });

    test('解不开的旧消息不搬，直接删除', () async {
      await storeReceived(bobContact, 'ok', '能解开', ts: 1);
      await LocalDatabase.insertMessage(StoredMessage(
        msgId: 'broken',
        sessionId: _oldSession,
        senderPublicKey: bobContact.x25519PublicKeyBase64,
        ciphertext: 'garbage',
        sequenceNumber: 0,
        timestamp: 2,
        direction: 'received',
      ));
      final renewed = contactFor(_newSession, 'a');
      expect(await service.adopt(bobContact, renewed), 1);
      expect(await LocalDatabase.getMessage('broken'), isNull);
      expect((await service.messages(renewed)).single.text, '能解开');
    });

    test('会话没变或旧联系人没有会话时什么都不做', () async {
      await storeReceived(bobContact, 'ok', '在', ts: 1);
      expect(await service.adopt(bobContact, bobContact), 0);
      expect(await service.adopt(contactFor('', ''), bobContact), 0);
      expect(await service.messages(bobContact), hasLength(1));
    });
  });

  test('reset 断开所有连接，之后可以重新 start', () async {
    await service.start();
    final first = await welcome();
    await service.reset();
    expect(first.ended, isTrue);
    expect(service.linkState(_oldSession).name, 'disconnected');
    await service.start();
    await _until(() => relay.connections.length == 2, what: '重新连接');
  });
}
