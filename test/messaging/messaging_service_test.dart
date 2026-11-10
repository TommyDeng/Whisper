import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:whisper/contact/contact.dart';
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

void main() {
  late IdentityKeyPair alice;
  late IdentityKeyPair bob;
  late Contact bobContact; // Alice 眼里的 Bob；Alice 是邀请人 a
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
  Future<FakeConnection> welcome({int count = 1}) async {
    await _until(() => relay.connections.length >= count, what: '第 $count 条连接');
    final connection = relay.last;
    connection.push({'type': 'welcome', 'peer': 'a', 'peerOnline': false});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return connection;
  }

  /// Bob 加密一条发给 Alice 的消息。
  Future<String> fromBob(String id, String text, {String role = 'b'}) async => MessageCodec.seal(
        key: await MessageCodec.deriveKey(
          myPrivateKey: bob.x25519PrivateKey,
          peerPublicKey: alice.x25519PublicKey,
          sessionId: _sessionId,
        ),
        sessionId: _sessionId,
        senderRole: role,
        messageId: id,
        content: ChatContent.text(text, sentAt: 1),
      );

  setUp(() async {
    AppDatabase.useForTesting(await AppDatabase.openAt(inMemoryDatabasePath, singleInstance: false));
    alice = await generateIdentityKeyPair();
    bob = await generateIdentityKeyPair();
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

  test('start 为有会话的联系人连接中继，身份是自己的角色', () async {
    await ContactStore.upsertContact(Contact(
      deviceId: 'nosession',
      name: '旧联系人',
      x25519PublicKeyBase64: bob.x25519PublicKeyBase64,
      ed25519PublicKeyBase64: bob.ed25519PublicKeyBase64,
      safetyCode: 'code',
      isVerified: false,
      createdAt: 1,
      lastMessageTime: 0,
    ));
    await service.start();
    await welcome();
    expect(relay.attempts, hasLength(1));
    expect(relay.attempts.single.path, '/session/$_sessionId');
    expect(relay.attempts.single.queryParameters['peer'], 'a');
  });

  test('发送：密文交给中继，状态随 stored / delivered 推进', () async {
    await service.start();
    final connection = await welcome();
    await service.sendText(bobContact, '你好 Bob');

    final frame = connection.sentOfType('msg').single;
    final id = frame['id'] as String;
    expect((frame['payload'] as String).contains('你好'), isFalse);
    // Bob 用自己的密钥能解开
    final opened = await MessageCodec.open(
      key: await MessageCodec.deriveKey(
        myPrivateKey: bob.x25519PrivateKey,
        peerPublicKey: alice.x25519PublicKey,
        sessionId: _sessionId,
      ),
      sessionId: _sessionId,
      senderRole: 'a',
      messageId: id,
      payload: frame['payload'] as String,
    );
    expect(opened.body, '你好 Bob');

    var message = (await service.messages(bobContact)).single;
    expect(message.text, '你好 Bob');
    expect(message.isSent, isTrue);
    expect(message.status, OutgoingStatus.sending);
    expect((await ContactStore.getContact('bob'))!.lastMessageTime, greaterThan(0));

    connection.push({'type': 'stored', 'id': id});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    message = (await service.messages(bobContact)).single;
    expect(message.status, OutgoingStatus.sent);

    connection.push({'type': 'delivered', 'id': id});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    message = (await service.messages(bobContact)).single;
    expect(message.status, OutgoingStatus.delivered);
  });

  test('接收：解密、落库、确认，并通知界面', () async {
    final updates = <String>[];
    final subscription = service.updates.listen(updates.add);
    await service.start();
    final connection = await welcome();
    updates.clear();

    connection.push({'type': 'msg', 'id': 'in-1', 'payload': await fromBob('in-1', '在吗'), 'ts': 5000});
    await _until(() => connection.sentOfType('ack').isNotEmpty, what: 'ack');
    expect(connection.sentOfType('ack').single['id'], 'in-1');

    final message = (await service.messages(bobContact)).single;
    expect(message.text, '在吗');
    expect(message.isSent, isFalse);
    expect(message.timestamp, 5000);
    expect(message.status, isNull);
    expect(updates, contains(_sessionId));
    expect((await ContactStore.getContact('bob'))!.lastMessageTime, 5000);
    await subscription.cancel();
  });

  test('重复投递只保存一次，但每次都确认', () async {
    await service.start();
    final connection = await welcome();
    final payload = await fromBob('in-1', '在吗');
    connection.push({'type': 'msg', 'id': 'in-1', 'payload': payload, 'ts': 5000});
    connection.push({'type': 'msg', 'id': 'in-1', 'payload': payload, 'ts': 5000});
    await _until(() => connection.sentOfType('ack').length == 2, what: '两次 ack');
    expect(await service.messages(bobContact), hasLength(1));
  });

  test('解不开的消息不保存，但仍确认', () async {
    await service.start();
    final connection = await welcome();
    connection.push({'type': 'msg', 'id': 'bad-1', 'payload': 'garbage', 'ts': 1});
    // 自己角色的密文被中继反射回来
    connection.push({
      'type': 'msg',
      'id': 'bad-2',
      'payload': await fromBob('bad-2', '反射', role: 'a'),
      'ts': 2,
    });
    // 换了 ID 的重放
    connection.push({'type': 'msg', 'id': 'bad-3', 'payload': await fromBob('other', '重放'), 'ts': 3});
    await _until(() => connection.sentOfType('ack').length == 3, what: '三次 ack');
    expect(await service.messages(bobContact), isEmpty);
  });

  test('离线时发送的消息在重启后重发；中继拒收的标为失败', () async {
    relay.refuse = true;
    await service.start();
    await service.sendText(bobContact, '离线消息');
    expect((await service.messages(bobContact)).single.status, OutgoingStatus.sending);
    await service.dispose();

    // 重启：新的服务实例，没有内存状态
    relay = FakeRelay();
    service = newService();
    await service.start();
    final connection = await welcome();
    final frame = connection.sentOfType('msg').single;
    final message = (await service.messages(bobContact)).single;
    expect(frame['id'], message.id);
    expect(message.text, '离线消息', reason: '重启后从密文解出自己发的消息');

    connection.push({'type': 'error', 'error': 'too-large', 'id': message.id});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect((await service.messages(bobContact)).single.status, OutgoingStatus.failed);
  });

  test('forget 断开连接并删除本地消息', () async {
    await service.start();
    final connection = await welcome();
    await service.sendText(bobContact, 'x');
    await service.forget(bobContact);
    expect(connection.closedByClient, isTrue);
    expect(await service.messages(bobContact), isEmpty);
    expect(service.linkState(_sessionId).name, 'disconnected');
    await expectLater(service.sendText(bobContact, 'y'), throwsStateError);
  });
}
