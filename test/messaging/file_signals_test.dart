// 大文件直传信令走加密的临时消息，与通话信令并列。见 docs/file-direct.md。
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

void main() {
  late IdentityKeyPair alice;
  late IdentityKeyPair bob;
  late Contact bobContact;
  late SecretKey bobKey;
  late FakeRelay relay;
  late MessagingService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<FakeConnection> welcome() async {
    await _until(() => relay.connections.isNotEmpty, what: '连接');
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
    AppDatabase.useForTesting(
      await AppDatabase.openAt(inMemoryDatabasePath, singleInstance: false),
    );
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

  test('发送：加密后作为临时消息发出，不落库', () async {
    await service.start();
    final connection = await welcome();

    final id = await service.sendFileSignal(
      bobContact,
      '{"k":"end","xfer":"x1","reason":"cancel"}',
    );

    expect(id, isNotNull);
    final frames = connection.sentOfType('msg');
    expect(frames, hasLength(1));
    expect(frames.single['id'], id);
    expect(frames.single['ephemeral'], true);
    expect(await LocalDatabase.getSessionMessages(_sessionId), isEmpty);

    final content = await MessageCodec.open(
      key: bobKey,
      sessionId: _sessionId,
      senderRole: 'a',
      messageId: id!,
      payload: frames.single['payload'] as String,
    );
    expect(content.type, ChatContent.typeFileSignal);
    expect(content.body, '{"k":"end","xfer":"x1","reason":"cancel"}');
  });

  test('没连上中继时 sendFileSignal 返回 null', () async {
    await service.start();
    await welcome();
    relay.last.drop();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await service.sendFileSignal(bobContact, '{}'), isNull);
  });

  test('接收：直传信令交给 fileSignals，不落库、不回回执', () async {
    final received = <({Contact contact, String body})>[];
    final subscription = service.fileSignals.listen(received.add);
    await service.start();
    final connection = await welcome();

    connection.push({
      'type': 'msg',
      'id': 'fsig-1',
      'payload': await fromBob(
        'fsig-1',
        ChatContent.fileSignal(
          '{"k":"end","xfer":"x9","reason":"cancel"}',
          sentAt: 1,
        ),
      ),
      'ts': 5000,
    });
    await _until(
      () =>
          connection.sentOfType('ack').any((frame) => frame['id'] == 'fsig-1'),
      what: 'ack',
    );

    expect(received, hasLength(1));
    expect(received.single.body, '{"k":"end","xfer":"x9","reason":"cancel"}');
    expect(await LocalDatabase.getSessionMessages(_sessionId), isEmpty);
    expect(connection.sentOfType('msg'), isEmpty);

    await subscription.cancel();
  });

  test('信令过长时抛 ArgumentError', () async {
    await service.start();
    await welcome();
    await expectLater(
      service.sendFileSignal(
        bobContact,
        'x' * (MessageCodec.maxSignalBytes + 1),
      ),
      throwsArgumentError,
    );
  });

  test('fileSignals 是广播流，可以多次监听', () async {
    final first = service.fileSignals.listen((_) {});
    final second = service.fileSignals.listen((_) {});
    await first.cancel();
    await second.cancel();
  });
}
