// 通话信令走加密的临时消息。行为说明见 tasks/call-signaling/spec.md。
import 'package:cryptography/cryptography.dart';
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

  Future<FakeConnection> welcome({int count = 1}) async {
    await _until(() => relay.connections.length >= count, what: '第 $count 条连接');
    final connection = relay.last;
    connection.push({'type': 'welcome', 'peer': 'a', 'peerOnline': true});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return connection;
  }

  Future<String> fromBob(String id, ChatContent content) => MessageCodec.seal(
        key: bobKey,
        sessionId: _sessionId,
        senderRole: 'b',
        messageId: id,
        content: content,
      );

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

  test('发送：加密后作为临时消息发出，不落库、断线重连后不重发', () async {
    await service.start();
    final connection = await welcome();

    final id = await service.sendCallSignal(bobContact, '{"k":"ringing","call":"c1"}');

    expect(id, isNotNull);
    final frames = connection.sentOfType('msg');
    expect(frames, hasLength(1));
    expect(frames.single['id'], id);
    expect(frames.single['ephemeral'], true);
    final content = await MessageCodec.open(
      key: bobKey,
      sessionId: _sessionId,
      senderRole: 'a',
      messageId: id!,
      payload: frames.single['payload'] as String,
    );
    expect(content.type, ChatContent.typeCall);
    expect(content.body, '{"k":"ringing","call":"c1"}');

    expect(await LocalDatabase.getSessionMessages(_sessionId), isEmpty);
    expect(await LocalDatabase.queryOutbox(_sessionId), isEmpty);
    expect(await service.messages(bobContact), isEmpty);

    connection.drop();
    final second = await welcome(count: 2);
    await _settle();
    expect(second.sentOfType('msg'), isEmpty);
  });

  test('发送：没连上中继、或联系人没有会话时返回 null，什么都不发', () async {
    await service.start();
    await _until(() => relay.connections.isNotEmpty, what: '连接');
    // 还没收到 welcome
    expect(await service.sendCallSignal(bobContact, '{}'), isNull);
    expect(relay.last.sentOfType('msg'), isEmpty);

    const stranger = Contact(
      deviceId: 'carol',
      name: 'Carol',
      x25519PublicKeyBase64: '',
      ed25519PublicKeyBase64: '',
      safetyCode: '',
      isVerified: false,
      createdAt: 1,
      lastMessageTime: 0,
      sessionId: 'session-unknown',
      peerRole: 'a',
    );
    expect(await service.sendCallSignal(stranger, '{}'), isNull);
  });

  test('发送：正文超过上限时抛 ArgumentError', () async {
    await service.start();
    final connection = await welcome();
    await expectLater(
      service.sendCallSignal(bobContact, 'x' * (MessageCodec.maxSignalBytes + 1)),
      throwsArgumentError,
    );
    expect(connection.sentOfType('msg'), isEmpty);
  });

  test('接收：通话信令交给 callSignals，确认给中继，不落库、不回回执、不更新联系人时间', () async {
    final received = <({Contact contact, String body})>[];
    final subscription = service.callSignals.listen(received.add);
    final updates = <String>[];
    await service.start();
    final connection = await welcome();
    final updatesSubscription = service.updates.listen(updates.add);

    connection.push({
      'type': 'msg',
      'id': 'sig-1',
      'payload': await fromBob('sig-1', const ChatContent.call('{"k":"ringing","call":"c9"}', sentAt: 1)),
      'ts': 5000,
    });
    await _until(() => connection.sentOfType('ack').any((frame) => frame['id'] == 'sig-1'), what: 'ack');
    await _settle();

    expect(received, hasLength(1));
    expect(received.single.contact.deviceId, 'bob');
    expect(received.single.contact.sessionId, _sessionId);
    expect(received.single.body, '{"k":"ringing","call":"c9"}');
    expect(await LocalDatabase.getSessionMessages(_sessionId), isEmpty);
    expect(await LocalDatabase.queryOutbox(_sessionId), isEmpty);
    expect(connection.sentOfType('msg'), isEmpty);
    expect((await ContactStore.getContact('bob'))!.lastMessageTime, 0);
    expect(updates, isEmpty);

    await subscription.cancel();
    await updatesSubscription.cancel();
  });

  test('接收：解不开的信令不会出现在 callSignals 里', () async {
    final received = <({Contact contact, String body})>[];
    final subscription = service.callSignals.listen(received.add);
    await service.start();
    final connection = await welcome();

    // 用错的 id 加密（附加数据对不上）
    connection.push({
      'type': 'msg',
      'id': 'sig-2',
      'payload': await fromBob('other-id', const ChatContent.call('{}', sentAt: 1)),
      'ts': 5000,
    });
    await _until(() => connection.sentOfType('ack').any((frame) => frame['id'] == 'sig-2'), what: 'ack');
    expect(received, isEmpty);
    await subscription.cancel();
  });

  test('中继的 dropped 帧转成 signalDropped', () async {
    final dropped = <({String sessionId, String id})>[];
    final subscription = service.signalDropped.listen(dropped.add);
    await service.start();
    final connection = await welcome();

    final id = await service.sendCallSignal(bobContact, '{}');
    connection.push({'type': 'dropped', 'id': id});
    await _until(() => dropped.isNotEmpty, what: 'dropped');

    expect(dropped.single, (sessionId: _sessionId, id: id!));
    await subscription.cancel();
  });

  test('callSignals 和 signalDropped 是广播流，可以在 start 之前、多次监听', () async {
    final first = service.callSignals.listen((_) {});
    final second = service.callSignals.listen((_) {});
    final third = service.signalDropped.listen((_) {});
    final fourth = service.signalDropped.listen((_) {});
    await first.cancel();
    await second.cancel();
    await third.cancel();
    await fourth.cancel();
  });
}
