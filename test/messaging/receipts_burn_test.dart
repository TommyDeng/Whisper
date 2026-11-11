// 端到端回执（delivered / read）和阅后即焚。行为说明见 tasks/msg-receipts-burn/spec.md。
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

const _sessionId = 'session-0000000000000000000001';

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
  late Contact bobContact; // Alice 眼里的 Bob；Alice 是邀请人 a
  late SecretKey bobKey;
  late FakeRelay relay;
  late MessagingService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  MessagingService newService() => MessagingService(
        baseUri: Uri.parse('ws://relay.test'),
        connector: relay.connect,
        identity: () async => alice,
        backoff: const [Duration(milliseconds: 10)],
      );

  /// 等连接建立并送上 welcome。
  Future<FakeConnection> welcome() async {
    await _until(() => relay.connections.isNotEmpty, what: '连接');
    final connection = relay.last;
    connection.push({'type': 'welcome', 'peer': 'a', 'peerOnline': false});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return connection;
  }

  /// 模拟重启：丢掉内存状态，换一个新的服务实例和新的中继连接。
  Future<FakeConnection> restart() async {
    await service.dispose();
    relay = FakeRelay();
    service = newService();
    await service.start();
    return welcome();
  }

  /// Bob 加密一条发给 Alice 的内容。
  Future<String> fromBob(String id, ChatContent content) => MessageCodec.seal(
        key: bobKey,
        sessionId: _sessionId,
        senderRole: 'b',
        messageId: id,
        content: content,
      );

  /// 中继把 Bob 的一条内容推给 Alice，并等 Alice 确认。
  Future<void> deliver(FakeConnection connection, String id, ChatContent content, {int ts = 5000}) async {
    connection.push({'type': 'msg', 'id': id, 'payload': await fromBob(id, content), 'ts': ts});
    await _until(
      () => connection.sentOfType('ack').any((frame) => frame['id'] == id),
      what: '$id 的 ack',
    );
  }

  /// Bob 解开 Alice 发出的一帧。
  Future<ChatContent> openFromAlice(Map<String, dynamic> frame) => MessageCodec.open(
        key: bobKey,
        sessionId: _sessionId,
        senderRole: 'a',
        messageId: frame['id'] as String,
        payload: frame['payload'] as String,
      );

  /// Alice 在这条连接上发出的全部回执（已解密），按发送顺序。
  Future<List<ChatContent>> receiptsOn(FakeConnection connection) async {
    final result = <ChatContent>[];
    for (final frame in connection.sentOfType('msg')) {
      final content = await openFromAlice(frame);
      if (content.type == ChatContent.typeReceipt) result.add(content);
    }
    return result;
  }

  setUp(() async {
    AppDatabase.useForTesting(await AppDatabase.openAt(inMemoryDatabasePath, singleInstance: false));
    alice = await generateIdentityKeyPair();
    bob = await generateIdentityKeyPair();
    bobKey = await MessageCodec.deriveKey(
      myPrivateKey: bob.x25519PrivateKey,
      peerPublicKey: alice.x25519PublicKey,
      sessionId: _sessionId,
    );
    bobContact = Contact(
      deviceId: 'bob',
      name: 'Bob',
      x25519PublicKeyBase64: bob.x25519PublicKeyBase64,
      ed25519PublicKeyBase64: bob.ed25519PublicKeyBase64,
      safetyCode: 'code',
      isVerified: false,
      createdAt: 1,
      lastMessageTime: 0,
      sessionId: _sessionId,
      peerRole: 'a',
    );
    await ContactStore.upsertContact(bobContact);
    relay = FakeRelay();
    service = newService();
  });

  tearDown(() async {
    await service.dispose();
    await AppDatabase.close();
  });

  group('送达回执', () {
    test('收到文本后给对方发一条加密的 delivered 回执', () async {
      await service.start();
      final connection = await welcome();
      await deliver(connection, 'in-1', const ChatContent.text('在吗', sentAt: 1));
      await _until(() => connection.sentOfType('msg').isNotEmpty, what: '回执');
      await _settle();

      final frame = connection.sentOfType('msg').single;
      expect(frame.keys.toSet(), {'type', 'id', 'payload'}, reason: '回执走可靠通道，不是 ephemeral');
      expect((frame['id'] as String).length, 22);
      final receipt = await openFromAlice(frame);
      expect(receipt.type, ChatContent.typeReceipt);
      expect(receipt.receiptKind, ChatContent.receiptDelivered);
      expect(receipt.ids, ['in-1']);

      // 回执不是聊天消息
      final messages = await service.messages(bobContact);
      expect(messages, hasLength(1));
      expect(messages.single.text, '在吗');
    });

    test('重复投递的消息不再发第二条回执', () async {
      await service.start();
      final connection = await welcome();
      final payload = await fromBob('in-1', const ChatContent.text('在吗', sentAt: 1));
      connection.push({'type': 'msg', 'id': 'in-1', 'payload': payload, 'ts': 5000});
      connection.push({'type': 'msg', 'id': 'in-1', 'payload': payload, 'ts': 5000});
      await _until(() => connection.sentOfType('ack').length == 2, what: '两次 ack');
      await _settle();
      expect(connection.sentOfType('msg'), hasLength(1));
    });

    test('解不开的消息不发回执', () async {
      await service.start();
      final connection = await welcome();
      connection.push({'type': 'msg', 'id': 'bad-1', 'payload': 'garbage', 'ts': 1});
      await _until(() => connection.sentOfType('ack').isNotEmpty, what: 'ack');
      await _settle();
      expect(connection.sentOfType('msg'), isEmpty);
    });

    test('中继还没收下的回执在重启后原样重发，收下后不再重发', () async {
      await service.start();
      var connection = await welcome();
      await deliver(connection, 'in-1', const ChatContent.text('在吗', sentAt: 1));
      await _until(() => connection.sentOfType('msg').isNotEmpty, what: '回执');
      final first = connection.sentOfType('msg').single;

      connection = await restart();
      await _until(() => connection.sentOfType('msg').isNotEmpty, what: '重发的回执');
      await _settle();
      final again = connection.sentOfType('msg').single;
      expect(again['id'], first['id']);
      expect(again['payload'], first['payload']);

      connection.push({'type': 'stored', 'id': first['id']});
      await _settle();
      connection = await restart();
      await _settle();
      expect(connection.sentOfType('msg'), isEmpty);
    });

    test('中继拒收的回执不再重发', () async {
      await service.start();
      var connection = await welcome();
      await deliver(connection, 'in-1', const ChatContent.text('在吗', sentAt: 1));
      await _until(() => connection.sentOfType('msg').isNotEmpty, what: '回执');
      final id = connection.sentOfType('msg').single['id'];
      connection.push({'type': 'error', 'error': 'too-large', 'id': id});
      await _settle();

      connection = await restart();
      await _settle();
      expect(connection.sentOfType('msg'), isEmpty);
    });

    test('forget 之后不再重发这个会话的回执', () async {
      await service.start();
      var connection = await welcome();
      await deliver(connection, 'in-1', const ChatContent.text('在吗', sentAt: 1));
      await _until(() => connection.sentOfType('msg').isNotEmpty, what: '回执');
      await service.forget(bobContact);

      // 联系人还在库里，重启后会重新连接
      connection = await restart();
      await _settle();
      expect(connection.sentOfType('msg'), isEmpty);
    });

    test('收到 delivered 回执：没有中继的 delivered 帧也变成已送达', () async {
      await service.start();
      final connection = await welcome();
      await service.sendText(bobContact, '你好 Bob');
      final id = connection.sentOfType('msg').single['id'] as String;
      connection.push({'type': 'stored', 'id': id});
      await _settle();
      expect((await service.messages(bobContact)).single.status, OutgoingStatus.sent);

      final updates = <String>[];
      final subscription = service.updates.listen(updates.add);
      await deliver(
        connection,
        'r-1',
        ChatContent.receipt(ChatContent.receiptDelivered, [id], sentAt: 2),
      );
      await _settle();

      final messages = await service.messages(bobContact);
      expect(messages, hasLength(1), reason: '回执本身不进聊天记录');
      expect(messages.single.status, OutgoingStatus.delivered);
      expect(updates, contains(_sessionId));
      expect(connection.sentOfType('msg'), hasLength(1), reason: '收到回执不再回一条回执');
      await subscription.cancel();
    });
  });

  group('阅后即焚', () {
    test('发送：内容带 burn 标记；对方读过之后本地删除', () async {
      await service.start();
      final connection = await welcome();
      await service.sendText(bobContact, '看完就没了', burn: true);
      final frame = connection.sentOfType('msg').single;
      final id = frame['id'] as String;
      final content = await openFromAlice(frame);
      expect(content.body, '看完就没了');
      expect(content.burn, isTrue);

      final shown = (await service.messages(bobContact)).single;
      expect(shown.burn, isTrue);
      expect(shown.text, '看完就没了');

      // 只是送达：还在
      await deliver(connection, 'r-1', ChatContent.receipt(ChatContent.receiptDelivered, [id], sentAt: 2));
      await _settle();
      expect((await service.messages(bobContact)).single.status, OutgoingStatus.delivered);

      await deliver(connection, 'r-2', ChatContent.receipt(ChatContent.receiptRead, [id], sentAt: 3));
      await _settle();
      expect(await service.messages(bobContact), isEmpty);
      expect(await LocalDatabase.getMessage(id), isNull);
    });

    test('普通消息默认不带 burn，收到 read 回执也不删除', () async {
      await service.start();
      final connection = await welcome();
      await service.sendText(bobContact, '普通消息');
      final frame = connection.sentOfType('msg').single;
      final id = frame['id'] as String;
      expect((await openFromAlice(frame)).burn, isFalse);
      expect((await service.messages(bobContact)).single.burn, isFalse);

      await deliver(connection, 'r-1', ChatContent.receipt(ChatContent.receiptRead, [id], sentAt: 3));
      await _settle();
      final message = (await service.messages(bobContact)).single;
      expect(message.text, '普通消息');
      expect(message.status, OutgoingStatus.delivered, reason: '读过自然也送达了');
    });

    test('回执动不了收到的消息，也动不了别的会话的消息', () async {
      await service.start();
      final connection = await welcome();
      await deliver(connection, 'in-1', const ChatContent.text('Bob 的焚毁消息', sentAt: 1, burn: true));
      await LocalDatabase.insertMessage(const StoredMessage(
        msgId: 'elsewhere',
        sessionId: 'session-0000000000000000000002',
        senderPublicKey: 'x',
        ciphertext: 'x',
        sequenceNumber: 0,
        timestamp: 1,
        direction: 'sent',
        burnAfterRead: true,
      ));

      await deliver(
        connection,
        'r-1',
        ChatContent.receipt(ChatContent.receiptRead, const ['in-1', 'elsewhere'], sentAt: 3),
      );
      await _settle();

      expect((await service.messages(bobContact)).single.text, 'Bob 的焚毁消息');
      final other = await LocalDatabase.getMessage('elsewhere');
      expect(other, isNotNull);
      expect(other!.delivered, isFalse);
    });

    test('接收：markRead 只为焚毁消息发 read 回执，purgeBurned 删掉已读的', () async {
      await service.start();
      final connection = await welcome();
      await deliver(connection, 'in-1', const ChatContent.text('普通', sentAt: 1), ts: 5000);
      await deliver(connection, 'in-2', const ChatContent.text('焚毁一', sentAt: 2, burn: true), ts: 5001);
      await deliver(connection, 'in-3', const ChatContent.text('焚毁二', sentAt: 3, burn: true), ts: 5002);
      await _until(() => connection.sentOfType('msg').length == 3, what: '三条 delivered 回执');

      var messages = await service.messages(bobContact);
      expect(messages.map((m) => m.burn), [false, true, true]);
      expect(await service.purgeBurned(), 0, reason: '还没读过的不删');

      await service.markRead(bobContact);
      await _until(() => connection.sentOfType('msg').length == 4, what: 'read 回执');
      await _settle();
      final receipts = await receiptsOn(connection);
      expect(receipts, hasLength(4));
      final read = receipts.last;
      expect(read.receiptKind, ChatContent.receiptRead);
      expect(read.ids.toSet(), {'in-2', 'in-3'}, reason: '一条回执带上全部刚读的焚毁消息，不含普通消息');

      // 读过之后还能看，直到 purgeBurned
      messages = await service.messages(bobContact);
      expect(messages.map((m) => m.text), ['普通', '焚毁一', '焚毁二']);
      expect((await LocalDatabase.getMessage('in-1'))!.read, isTrue);
      expect((await LocalDatabase.getMessage('in-2'))!.read, isTrue);

      // 再标一次：没有新读的，不再发回执
      await service.markRead(bobContact);
      await _settle();
      expect(connection.sentOfType('msg'), hasLength(4));

      final updates = <String>[];
      final subscription = service.updates.listen(updates.add);
      expect(await service.purgeBurned(sessionId: 'session-0000000000000000000002'), 0);
      expect(await service.purgeBurned(sessionId: _sessionId), 2);
      await _settle();
      expect(updates, contains(_sessionId));
      messages = await service.messages(bobContact);
      expect(messages.map((m) => m.text), ['普通']);
      expect(await LocalDatabase.getMessage('in-2'), isNull);
      await subscription.cancel();
    });

    test('只有普通消息时 markRead 不发任何回执', () async {
      await service.start();
      final connection = await welcome();
      await deliver(connection, 'in-1', const ChatContent.text('普通', sentAt: 1));
      await _until(() => connection.sentOfType('msg').length == 1, what: 'delivered 回执');
      await service.markRead(bobContact);
      await _settle();
      expect(connection.sentOfType('msg'), hasLength(1));
      expect((await LocalDatabase.getMessage('in-1'))!.read, isTrue);
    });

    test('read 回执也可靠：中继没收下就重启，会原样重发', () async {
      await service.start();
      var connection = await welcome();
      await deliver(connection, 'in-1', const ChatContent.text('焚毁', sentAt: 1, burn: true));
      await _until(() => connection.sentOfType('msg').length == 1, what: 'delivered 回执');
      connection.push({'type': 'stored', 'id': connection.sentOfType('msg').single['id']});
      await service.markRead(bobContact);
      await _until(() => connection.sentOfType('msg').length == 2, what: 'read 回执');
      final readFrame = connection.sentOfType('msg').last;
      await _settle();

      connection = await restart();
      await _until(() => connection.sentOfType('msg').isNotEmpty, what: '重发的 read 回执');
      await _settle();
      final again = connection.sentOfType('msg').single;
      expect(again['id'], readFrame['id']);
      expect(again['payload'], readFrame['payload']);
    });
  });
}
