// 通话记录：recordCall 落库、messages() 解出、未接来电算未读。
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:whisper/contact/contact.dart';
import 'package:whisper/identity/identity_store.dart';
import 'package:whisper/messaging/call_record.dart';
import 'package:whisper/messaging/messaging_service.dart';
import 'package:whisper/storage/storage.dart';

import '../relay/fake_relay.dart';

const _sessionId = 'session-0000000000000000000001';

void main() {
  late IdentityKeyPair alice;
  late IdentityKeyPair bob;
  late Contact bobContact;
  late FakeRelay relay;
  late MessagingService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    AppDatabase.useForTesting(
      await AppDatabase.openAt(inMemoryDatabasePath, singleInstance: false),
    );
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

  test('记一通接通的呼出通话：方向靠右、带时长、能解出', () async {
    await service.recordCall(
      bobContact,
      const CallRecord(
        outgoing: true,
        outcome: CallOutcome.completed,
        duration: Duration(minutes: 5, seconds: 23),
      ),
    );

    final messages = await service.messages(bobContact);
    expect(messages, hasLength(1));
    final message = messages.single;
    expect(message.isSent, isTrue); // 呼出：靠右
    expect(message.text, isNull);
    expect(message.file, isNull);
    final call = message.call;
    expect(call, isNotNull);
    expect(call!.outgoing, isTrue);
    expect(call.outcome, CallOutcome.completed);
    expect(call.duration, const Duration(minutes: 5, seconds: 23));
  });

  test('重新读库也能解出通话记录（不只靠内存缓存）', () async {
    await service.recordCall(
      bobContact,
      const CallRecord(outgoing: true, outcome: CallOutcome.rejected),
    );

    // 换一个全新的服务实例，强制从数据库解密，验证 seal/open 的角色一致。
    final fresh = MessagingService(
      baseUri: Uri.parse('ws://relay.test'),
      connector: relay.connect,
      identity: () async => alice,
      backoff: const [Duration(milliseconds: 10)],
    );
    addTearDown(fresh.dispose);

    final messages = await fresh.messages(bobContact);
    expect(messages.single.call?.outcome, CallOutcome.rejected);
  });

  test('未接来电：靠左、算未读', () async {
    await service.recordCall(
      bobContact,
      const CallRecord(outgoing: false, outcome: CallOutcome.missed),
    );

    final messages = await service.messages(bobContact);
    expect(messages.single.isSent, isFalse); // 来电：靠左
    expect(messages.single.call?.outcome, CallOutcome.missed);

    final unread = await LocalDatabase.unreadCounts();
    expect(unread[_sessionId], 1);
  });

  test('自己拒接的来电：靠左、不算未读', () async {
    await service.recordCall(
      bobContact,
      const CallRecord(outgoing: false, outcome: CallOutcome.declined),
    );

    expect((await service.messages(bobContact)).single.isSent, isFalse);
    expect(await LocalDatabase.unreadCounts(), isEmpty);
  });

  test('记通话会把它设为联系人最近一条消息的时间', () async {
    await service.recordCall(
      bobContact,
      const CallRecord(outgoing: true, outcome: CallOutcome.canceled),
    );
    final updated = await ContactStore.getContact('bob');
    expect(updated!.lastMessageTime, greaterThan(0));
  });

  test('读聊天后未接来电标为已读，清掉未读红点', () async {
    await service.recordCall(
      bobContact,
      const CallRecord(outgoing: false, outcome: CallOutcome.missed),
    );
    expect((await LocalDatabase.unreadCounts())[_sessionId], 1);

    await service.markRead(bobContact);
    expect(await LocalDatabase.unreadCounts(), isEmpty);
  });
}
