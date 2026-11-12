import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:whisper/contact/contact.dart';
import 'package:whisper/files/file_direct_service.dart';
import 'package:whisper/files/file_relay_transfer.dart';
import 'package:whisper/files/file_share_service.dart';
import 'package:whisper/identity/identity_store.dart';
import 'package:whisper/messaging/messaging_service.dart';
import 'package:whisper/storage/storage.dart';

import '../relay/fake_relay.dart';
import 'fake_file_direct_transport.dart';
import 'fake_file_link.dart';
import 'fake_file_relay.dart';

const _sessionId = 'session-direct-000000000000000001';
const _threshold = 1000;

Future<void> _until(bool Function() condition, {String what = '条件'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late IdentityKeyPair aliceKeys;
  late IdentityKeyPair bobKeys;
  late Contact bobContact;
  late Contact aliceContact;
  late MessagingService aliceMessaging;
  late MessagingService bobMessaging;
  late FakeFileRelay fileRelay;
  late FileShareService aliceFiles;
  late FileShareService bobFiles;
  late Directory dir;
  late PipeHub hub;
  late FakeLinkPair links;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    AppDatabase.useForTesting(
      await AppDatabase.openAt(inMemoryDatabasePath, singleInstance: false),
    );
    aliceKeys = await generateIdentityKeyPair();
    bobKeys = await generateIdentityKeyPair();
    bobContact = Contact(
      deviceId: 'bob',
      name: 'Bob',
      x25519PublicKeyBase64: bobKeys.x25519PublicKeyBase64,
      ed25519PublicKeyBase64: bobKeys.ed25519PublicKeyBase64,
      safetyCode: 'code',
      isVerified: false,
      createdAt: 1,
      lastMessageTime: 0,
      sessionId: _sessionId,
      peerRole: 'a',
    );
    aliceContact = Contact(
      deviceId: 'alice',
      name: 'Alice',
      x25519PublicKeyBase64: aliceKeys.x25519PublicKeyBase64,
      ed25519PublicKeyBase64: aliceKeys.ed25519PublicKeyBase64,
      safetyCode: 'code',
      isVerified: false,
      createdAt: 1,
      lastMessageTime: 0,
      sessionId: _sessionId,
      peerRole: 'b',
    );
    await ContactStore.upsertContact(bobContact);
    await ContactStore.upsertContact(aliceContact);

    final aliceRelay = FakeRelay();
    aliceMessaging = MessagingService(
      baseUri: Uri.parse('ws://relay.test'),
      connector: aliceRelay.connect,
      identity: () async => aliceKeys,
      backoff: const [Duration(milliseconds: 10)],
    );
    await aliceMessaging.start();
    await _until(() => aliceRelay.connections.isNotEmpty, what: 'Alice 连接');
    aliceRelay.last.push({'type': 'welcome', 'peer': 'a', 'peerOnline': true});

    final bobRelay = FakeRelay();
    bobMessaging = MessagingService(
      baseUri: Uri.parse('ws://relay.test'),
      connector: bobRelay.connect,
      identity: () async => bobKeys,
      backoff: const [Duration(milliseconds: 10)],
    );
    await bobMessaging.start();
    await _until(() => bobRelay.connections.isNotEmpty, what: 'Bob 连接');
    bobRelay.last.push({'type': 'welcome', 'peer': 'b', 'peerOnline': true});
    await Future<void>.delayed(const Duration(milliseconds: 30));

    fileRelay = FakeFileRelay();
    hub = PipeHub(aliceView: bobContact, bobView: aliceContact);
    links = FakeLinkPair();
    aliceFiles = FileShareService(
      messaging: aliceMessaging,
      transfer: FileRelayTransfer(fileRelay),
      direct: FileDirectService(
        transport: hub.alice,
        createLink: () => links.alice,
        offerTimeout: const Duration(seconds: 2),
        connectTimeout: const Duration(seconds: 2),
        progressTimeout: const Duration(seconds: 2),
      ),
      directThreshold: _threshold,
    );
    bobFiles = FileShareService(
      messaging: bobMessaging,
      transfer: FileRelayTransfer(fileRelay),
      direct: FileDirectService(
        transport: hub.bob,
        createLink: () => links.bob,
        offerTimeout: const Duration(seconds: 2),
        connectTimeout: const Duration(seconds: 2),
        progressTimeout: const Duration(seconds: 2),
      ),
      directThreshold: _threshold,
    );
    dir = await Directory.systemTemp.createTemp('whisper-share-direct-');
  });

  tearDown(() async {
    await aliceFiles.dispose();
    await bobFiles.dispose();
    await aliceMessaging.dispose();
    await bobMessaging.dispose();
    await AppDatabase.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> source(String name, int size) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(List<int>.generate(size, (i) => i & 0xff));
    return file;
  }

  test('不超过阈值的文件仍走中转', () async {
    final file = await source('small.bin', _threshold);
    final id = await aliceFiles.send(bobContact, file);
    expect(id, isNotNull);
    expect(fileRelay.files, isNotEmpty);
    expect(aliceFiles.uploads(bobContact.sessionId), isEmpty);
  });

  test('超过阈值走直传，成功后不把文件传到中转', () async {
    final file = await source('big.bin', _threshold + 1);
    final target = File('${dir.path}/saved.bin');
    final sending = aliceFiles.send(bobContact, file);
    await _until(
      () => bobFiles.incoming(aliceContact.sessionId).isNotEmpty,
      what: '来传',
    );
    final incoming = bobFiles.incoming(aliceContact.sessionId).single;
    expect(incoming.needsAccept, isTrue);
    expect(incoming.isDirect, isTrue);
    expect(incoming.total, _threshold + 1);

    final received = bobFiles.acceptIncoming(incoming.id, target);
    final msgId = await sending;
    final saved = await received;
    expect(msgId, isNotNull);
    expect(saved, isNotNull);
    expect(await saved!.readAsBytes(), await file.readAsBytes());
    expect(fileRelay.files, isEmpty);
    expect(aliceFiles.uploads(bobContact.sessionId), isEmpty);
    final paths = await aliceFiles.localPaths(bobContact.sessionId);
    expect(paths[msgId!], file.absolute.path);
  });

  test('没有直传服务时超过阈值失败，且不走中转', () async {
    await aliceFiles.dispose();
    aliceFiles = FileShareService(
      messaging: aliceMessaging,
      transfer: FileRelayTransfer(fileRelay),
      directThreshold: _threshold,
    );
    final file = await source('big.bin', _threshold + 1);
    final id = await aliceFiles.send(bobContact, file);
    expect(id, isNull);
    final state = aliceFiles.uploads(bobContact.sessionId).single;
    expect(state.isDirect, isTrue);
    expect(state.error, 'failed');
    expect(fileRelay.files, isEmpty);
  });
}
