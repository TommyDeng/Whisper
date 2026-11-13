import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:whisper/contact/contact.dart';
import 'package:whisper/e2ee/message.dart';
import 'package:whisper/files/file_cipher.dart';
import 'package:whisper/files/file_offer.dart';
import 'package:whisper/files/file_relay_api.dart';
import 'package:whisper/files/file_relay_transfer.dart';
import 'package:whisper/files/file_share_service.dart';
import 'package:whisper/identity/identity_store.dart';
import 'package:whisper/messaging/message_codec.dart';
import 'package:whisper/messaging/messaging_service.dart';
import 'package:whisper/storage/storage.dart';

import '../relay/fake_relay.dart';
import 'fake_file_relay.dart';

const _sessionId = 'session-0000000000000000000001';
const _auth = FileRelayAuth(sessionId: _sessionId, peer: 'a');
const _mib = FileCipher.chunkSize;

Future<void> _until(bool Function() condition, {String what = '条件'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late IdentityKeyPair alice;
  late IdentityKeyPair bob;
  late Contact bobContact; // Alice 眼里的 Bob；Alice 是邀请人 a
  late FakeRelay relay;
  late FakeConnection connection;
  late MessagingService messaging;
  late FakeFileRelay fileRelay;
  late FileRelayTransfer transfer;
  late FileShareService files;
  late Directory dir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

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
    messaging = MessagingService(
      baseUri: Uri.parse('ws://relay.test'),
      connector: relay.connect,
      identity: () async => alice,
      backoff: const [Duration(milliseconds: 10)],
    );
    await messaging.start();
    await _until(() => relay.connections.isNotEmpty, what: '连接');
    connection = relay.last;
    connection.push({'type': 'welcome', 'peer': 'a', 'peerOnline': false});
    await _settle();

    fileRelay = FakeFileRelay();
    transfer = FileRelayTransfer(fileRelay, retryDelay: Duration.zero);
    files = FileShareService(messaging: messaging, transfer: transfer);
    dir = await Directory.systemTemp.createTemp('whisper_file_share_');
  });

  tearDown(() async {
    await files.dispose();
    await messaging.dispose();
    await AppDatabase.close();
    await dir.delete(recursive: true);
  });

  Future<File> source(int size, [String name = '报告.pdf']) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(pattern(size), flush: true);
    return file;
  }

  Future<dynamic> bobKey() async => MessageCodec.deriveKey(
        myPrivateKey: bob.x25519PrivateKey,
        peerPublicKey: alice.x25519PublicKey,
        sessionId: _sessionId,
      );

  /// Bob 发来一条消息。
  Future<void> fromBob(String id, ChatContent content, {int ts = 5000}) async {
    final payload = await MessageCodec.seal(
      key: await bobKey(),
      sessionId: _sessionId,
      senderRole: 'b',
      messageId: id,
      content: content,
    );
    connection.push({'type': 'msg', 'id': id, 'payload': payload, 'ts': ts});
    await _settle();
  }

  /// Bob 把一个文件传到中继，返回他要发的 offer 和原文件。
  Future<({FileOffer offer, File file})> bobUploads(int size, [String name = 'from-bob.bin']) async {
    final file = await source(size, name);
    final offer = await transfer.upload(file, auth: _auth);
    fileRelay.calls.clear();
    return (offer: offer, file: file);
  }

  Future<ChatMessage> receivedFile(int size) async {
    final up = await bobUploads(size);
    await fromBob('in-file', ChatContent.file(up.offer.encode(), sentAt: 1));
    return (await messaging.messages(bobContact)).single;
  }

  group('文件消息', () {
    test('sendFile：落库、加密发出，对方能解出同一个 offer', () async {
      final up = await bobUploads(100);
      final id = await messaging.sendFile(bobContact, up.offer);

      final frame = connection.sentOfType('msg').single;
      expect(frame['id'], id);
      final payload = frame['payload'] as String;
      expect(payload.contains(up.offer.fileId), isFalse);
      final opened = await MessageCodec.open(
        key: await bobKey(),
        sessionId: _sessionId,
        senderRole: 'a',
        messageId: id,
        payload: payload,
      );
      expect(opened.type, ChatContent.typeFile);
      expect(opened.burn, isFalse);
      expect(FileOffer.decode(opened.body).fileId, up.offer.fileId);

      final message = (await messaging.messages(bobContact)).single;
      expect(message.id, id);
      expect(message.isSent, isTrue);
      expect(message.text, isNull);
      expect(message.file!.fileId, up.offer.fileId);
      expect(message.status, OutgoingStatus.sending);
      connection.push({'type': 'stored', 'id': id});
      await _settle();
      expect((await messaging.messages(bobContact)).single.status, OutgoingStatus.sent);
    });

    test('收到文件消息：落库、确认、回 delivered 回执；换个实例也读得出来', () async {
      final up = await bobUploads(100);
      await fromBob('in-1', ChatContent.file(up.offer.encode(), sentAt: 1));

      expect(connection.sentOfType('ack').single['id'], 'in-1');
      expect(connection.sentOfType('msg'), hasLength(1), reason: 'delivered 回执');
      var message = (await messaging.messages(bobContact)).single;
      expect(message.isSent, isFalse);
      expect(message.text, isNull);
      expect(message.file!.name, 'from-bob.bin');
      expect(message.file!.size, 100);
      expect(message.file!.keys.key, up.offer.keys.key);
      expect(message.burn, isFalse);

      // 重复投递不重复保存
      await fromBob('in-1', ChatContent.file(up.offer.encode(), sentAt: 1));
      expect(await messaging.messages(bobContact), hasLength(1));

      final fresh = MessagingService(
        baseUri: Uri.parse('ws://relay.test'),
        connector: relay.connect,
        identity: () async => alice,
      );
      addTearDown(fresh.dispose);
      message = (await fresh.messages(bobContact)).single;
      expect(message.file!.fileId, up.offer.fileId);
    });

    test('文件描述不合格的文件消息丢弃，但仍确认', () async {
      await fromBob('bad-1', const ChatContent.file('not json', sentAt: 1));
      await fromBob('bad-2', const ChatContent.file('{"v":1,"id":"x"}', sentAt: 1));
      expect(await messaging.messages(bobContact), isEmpty);
      expect(connection.sentOfType('ack').map((f) => f['id']), ['bad-1', 'bad-2']);
      expect(connection.sentOfType('msg'), isEmpty, reason: '不回回执');
    });

    test('文件消息不支持阅后即焚：对方带了 burn 也按普通消息存', () async {
      final up = await bobUploads(10);
      await fromBob(
        'in-1',
        ChatContent(type: ChatContent.typeFile, body: up.offer.encode(), sentAt: 1, burn: true),
      );
      expect((await messaging.messages(bobContact)).single.burn, isFalse);
      expect((await LocalDatabase.getMessage('in-1'))!.burnAfterRead, isFalse);
    });

    test('过长的文件描述不能发出', () async {
      await expectLater(
        MessageCodec.seal(
          key: await bobKey(),
          sessionId: _sessionId,
          senderRole: 'b',
          messageId: 'x',
          content: ChatContent.file('a' * (MessageCodec.maxFileBodyBytes + 1), sentAt: 1),
        ),
        throwsArgumentError,
      );
    });

    test('重新配对后文件消息跟着搬到新会话', () async {
      final up = await bobUploads(10);
      await fromBob('in-1', ChatContent.file(up.offer.encode(), sentAt: 1));
      await LocalDatabase.setFilePath('in-1', '/tmp/saved.bin');
      final renewed = Contact(
        deviceId: 'bob',
        name: 'Bob',
        x25519PublicKeyBase64: bob.x25519PublicKeyBase64,
        ed25519PublicKeyBase64: bob.ed25519PublicKeyBase64,
        safetyCode: 'code',
        isVerified: false,
        createdAt: 1,
        lastMessageTime: 0,
        sessionId: 'session-0000000000000000000002',
        peerRole: 'b',
      );
      await messaging.detach(bobContact);
      expect(await messaging.adopt(bobContact, renewed), 1);
      final message = (await messaging.messages(renewed)).single;
      expect(message.file!.fileId, up.offer.fileId);
      expect(await files.localPaths(renewed.sessionId), {'in-1': '/tmp/saved.bin'});
    });
  });

  group('本地路径记录', () {
    StoredMessage stored(String id, {int ts = 1000, bool burn = false, String direction = 'received'}) =>
        StoredMessage(
          msgId: id,
          sessionId: _sessionId,
          senderPublicKey: 'k',
          ciphertext: 'c',
          sequenceNumber: 0,
          timestamp: ts,
          direction: direction,
          burnAfterRead: burn,
        );

    Future<int> rows() async {
      final db = await AppDatabase.database;
      final result = await db.rawQuery('SELECT COUNT(*) AS n FROM file_transfers');
      return result.single['n'] as int;
    }

    test('记录、覆盖、按会话查询；消息不存在时不记', () async {
      await LocalDatabase.insertMessage(stored('m1'));
      await LocalDatabase.setFilePath('m1', '/a');
      await LocalDatabase.setFilePath('m1', '/b');
      await LocalDatabase.setFilePath('ghost', '/c');
      expect(await LocalDatabase.getFilePaths(_sessionId), {'m1': '/b'});
      expect(await LocalDatabase.getFilePaths('other'), isEmpty);
      expect(await rows(), 1);
    });

    test('消息从任何路径被删，记录都跟着删', () async {
      Future<void> seed(String id, {int ts = 1000, bool burn = false, String direction = 'received'}) async {
        await LocalDatabase.insertMessage(stored(id, ts: ts, burn: burn, direction: direction));
        await LocalDatabase.setFilePath(id, '/$id');
      }

      await seed('direct');
      await LocalDatabase.deleteMessage('direct');
      expect(await rows(), 0);

      await seed('old', ts: 10);
      await seed('new', ts: 9000);
      await LocalDatabase.purgeExpired(5000);
      expect(await LocalDatabase.getFilePaths(_sessionId), {'new': '/new'});

      await seed('burned-in', burn: true);
      await LocalDatabase.markRead('burned-in');
      await LocalDatabase.deleteReadBurned();
      expect((await LocalDatabase.getFilePaths(_sessionId)).keys, ['new']);

      await seed('burned-out', burn: true, direction: 'sent');
      await LocalDatabase.applyReceipt(sessionId: _sessionId, msgIds: ['burned-out'], deleteBurned: true);
      expect((await LocalDatabase.getFilePaths(_sessionId)).keys, ['new']);

      // 搬迁：重新加密过的留下，其余丢弃
      await seed('lost');
      await LocalDatabase.moveSessionMessages(
        fromSessionId: _sessionId,
        toSessionId: 'S2',
        rewritten: {'new': 'c2'},
        peerPublicKey: 'k2',
      );
      expect(await LocalDatabase.getFilePaths('S2'), {'new': '/new'});
      expect(await rows(), 1);

      await LocalDatabase.deleteSessionMessages('S2');
      expect(await rows(), 0);
    });
  });

  group('发送', () {
    test('上传后发文件消息并记下源文件路径', () async {
      final file = await source(_mib + 10);
      final events = <String>[];
      final sub = files.updates.listen(events.add);
      addTearDown(sub.cancel);

      final id = await files.sendViaRelay(bobContact, file);
      expect(id, isNotNull);
      expect(files.uploads(_sessionId), isEmpty);
      expect(events, isNotEmpty);
      expect(events.toSet(), {_sessionId});

      final message = (await messaging.messages(bobContact)).single;
      expect(message.id, id);
      expect(message.file!.name, '报告.pdf');
      expect(message.file!.size, _mib + 10);
      expect(fileRelay.files[message.file!.fileId], hasLength(2));
      expect(fileRelay.deleted, isEmpty);
      expect(await files.localPaths(_sessionId), {id: file.absolute.path});
      expect(connection.sentOfType('msg').single['id'], id);
    });

    test('上传途中能看到进度，可以取消；取消后不发消息、删掉已上传的块', () async {
      final file = await source(3 * _mib);
      late FileTransferState seen;
      fileRelay.before = (op, index) async {
        if (op == 'put' && index == 1) {
          seen = files.uploads(_sessionId).single;
          expect(seen.isUpload, isTrue);
          expect(seen.name, '报告.pdf');
          expect(seen.total, 3 * _mib);
          expect(seen.done, _mib);
          expect(seen.failed, isFalse);
          files.cancel(seen.id);
        }
      };
      expect(await files.sendViaRelay(bobContact, file), isNull);
      expect(files.uploads(_sessionId), isEmpty);
      expect(await messaging.messages(bobContact), isEmpty);
      expect(fileRelay.files, isEmpty);
      expect(connection.sentOfType('msg'), isEmpty);
    });

    test('失败：状态里留下原因，cancel 清掉', () async {
      fileRelay.before = (op, index) async {
        if (op == 'put') throw const FileRelayException(0, 'network');
      };
      expect(await files.sendViaRelay(bobContact, await source(10)), isNull);
      final state = files.uploads(_sessionId).single;
      expect(state.error, 'network');
      expect(await messaging.messages(bobContact), isEmpty);

      files.cancel(state.id);
      expect(files.uploads(_sessionId), isEmpty);

      expect(await files.sendViaRelay(bobContact, File('${dir.path}/missing.bin')), isNull);
      expect(files.uploads(_sessionId).single.error, 'failed');
    });

    test('消息发不出去（会话已不在）：删掉刚上传的块', () async {
      await messaging.detach(bobContact);
      expect(await files.sendViaRelay(bobContact, await source(10)), isNull);
      expect(files.uploads(_sessionId).single.error, 'failed');
      expect(fileRelay.files, isEmpty);
      expect(fileRelay.deleted, hasLength(1));
    });
  });

  group('图片自动下载', () {
    late Directory images;

    setUp(() async {
      images = await Directory.systemTemp.createTemp('whisper_file_images_');
      await files.dispose();
      files = FileShareService(
        messaging: messaging,
        transfer: transfer,
        imageDirectory: () async => images,
        autoImageMaxBytes: 1000,
      );
    });

    tearDown(() => images.delete(recursive: true));

    Future<String> receive(int size, String name) async {
      final up = await bobUploads(size, name);
      await fromBob('in-file', ChatContent.file(up.offer.encode(), sentAt: 1));
      return (await messaging.messages(bobContact)).single.id;
    }

    Future<String?> boundPath(String msgId) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        final path = (await files.localPaths(_sessionId))[msgId];
        if (path != null) return path;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return null;
    }

    test('收到的图片自动下载到图片目录并绑定到消息', () async {
      final id = await receive(700, 'photo.JPG');
      final path = await boundPath(id);
      expect(path, isNotNull);
      final saved = File(path!);
      expect(saved.parent.path, images.absolute.path);
      expect(saved.path.endsWith('.jpg'), isTrue);
      expect(
        await saved.readAsBytes(),
        await File('${dir.path}/photo.JPG').readAsBytes(),
      );
      expect(files.downloadState(id), isNull);
    });

    test('普通文件不自动下载', () async {
      final id = await receive(700, 'report.pdf');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect((await files.localPaths(_sessionId))[id], isNull);
      expect(images.listSync(), isEmpty);
    });

    test('超过上限的图片不自动下载', () async {
      final id = await receive(1001, 'big.png');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect((await files.localPaths(_sessionId))[id], isNull);
      expect(images.listSync(), isEmpty);
    });
  });

  group('下载', () {
    test('下载到目标位置并记下路径', () async {
      final message = await receivedFile(2 * _mib + 7);
      final target = File('${dir.path}/saved.bin');
      final saved = await files.download(bobContact, message, target);
      expect(saved!.path, target.path);
      expect(await saved.readAsBytes(), await File('${dir.path}/from-bob.bin').readAsBytes());
      expect(files.downloadState(message.id), isNull);
      expect(await files.localPaths(_sessionId), {message.id: target.absolute.path});
      expect(fileRelay.deleted, [message.file!.fileId]);
    });

    test('取消后可以续传；同一条消息不能同时下载两次', () async {
      final message = await receivedFile(3 * _mib);
      final target = File('${dir.path}/saved.bin');
      fileRelay.before = (op, index) async {
        if (op == 'get' && index == 1) {
          final state = files.downloadState(message.id)!;
          expect(state.isUpload, isFalse);
          expect(state.done, _mib);
          expect(state.total, 3 * _mib);
          expect(() => files.download(bobContact, message, target), throwsStateError);
          files.cancel(message.id);
        }
      };
      expect(await files.download(bobContact, message, target), isNull);
      expect(files.downloadState(message.id), isNull);
      expect(await File('${target.path}.part').length(), 2 * _mib);
      expect(await files.localPaths(_sessionId), isEmpty);

      fileRelay.before = null;
      fileRelay.calls.clear();
      final saved = await files.download(bobContact, message, target);
      expect(fileRelay.calls, ['get 2', 'delete']);
      expect(await saved!.length(), 3 * _mib);
    });

    test('失败：状态里留下原因，可以重试', () async {
      final message = await receivedFile(_mib + 1);
      final target = File('${dir.path}/saved.bin');
      fileRelay.before = (op, index) async {
        if (op == 'get' && index == 1) throw const FileRelayException(0, 'network');
      };
      expect(await files.download(bobContact, message, target), isNull);
      expect(files.downloadState(message.id)!.error, 'network');

      fileRelay.before = null;
      final saved = await files.download(bobContact, message, target);
      expect(saved, isNotNull);
      expect(files.downloadState(message.id), isNull);
    });

    test('中继上已过期：not-found', () async {
      final message = await receivedFile(10);
      fileRelay.files.clear();
      expect(await files.download(bobContact, message, File('${dir.path}/saved.bin')), isNull);
      expect(files.downloadState(message.id)!.error, 'not-found');
      files.cancel(message.id);
      expect(files.downloadState(message.id), isNull);
    });

    test('不是文件消息抛 ArgumentError', () async {
      await fromBob('t-1', const ChatContent.text('hi', sentAt: 1));
      final message = (await messaging.messages(bobContact)).single;
      expect(
        () => files.download(bobContact, message, File('${dir.path}/x')),
        throwsArgumentError,
      );
    });

    test('cancelSession / reset 取消进行中的传输', () async {
      final message = await receivedFile(3 * _mib);
      fileRelay.before = (op, index) async {
        if (op == 'get' && index == 1) files.cancelSession(_sessionId);
        if (op == 'put' && index == 1) files.reset();
      };
      expect(await files.download(bobContact, message, File('${dir.path}/saved.bin')), isNull);
      expect(files.downloadState(message.id), isNull);

      expect(await files.sendViaRelay(bobContact, await source(3 * _mib, 'up.bin')), isNull);
      expect(files.uploads(_sessionId), isEmpty);
      expect(fileRelay.count('put 2'), 0);
    });
  });
}
