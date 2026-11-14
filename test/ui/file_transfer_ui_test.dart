import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:whisper/contact/contact.dart';
import 'package:whisper/files/file_cipher.dart';
import 'package:whisper/files/file_offer.dart';
import 'package:whisper/files/file_relay_api.dart';
import 'package:whisper/files/file_relay_transfer.dart';
import 'package:whisper/files/file_share_service.dart';
import 'package:whisper/identity/identity_store.dart';
import 'package:whisper/messaging/message_codec.dart';
import 'package:whisper/messaging/messaging_service.dart';
import 'package:whisper/storage/storage.dart';
import 'package:whisper/ui/app_theme.dart';
import 'package:whisper/ui/chat_images.dart';
import 'package:whisper/ui/chat_screen.dart';
import 'package:whisper/ui/file_transfer_ui.dart';

import '../files/fake_file_relay.dart';
import '../relay/fake_relay.dart';

const _sessionId = 'session-0000000000000000000001';
const _auth = FileRelayAuth(sessionId: _sessionId, peer: 'a');
const _codes = [
  'too-large',
  'network',
  'not-found',
  'corrupt',
  'changed',
  'rejected',
  'failed',
];

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String what = '条件',
}) async {
  // widget 测试里 DateTime.now() 可能被 FakeAsync 停住，所以用步数限制等待。
  for (var step = 0; step < 250; step++) {
    if (condition()) return;
    await tester.pump();
    // 让 sqflite、文件 I/O 等真实异步在 FakeAsync 之外跑完
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  fail('等待超时：$what');
}

/// 一张 1x1 的 PNG。
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// 等图片真正解码、排版出大小，之后才点得到。
Future<void> _pumpUntilImageShown(WidgetTester tester) => _pumpUntil(
  tester,
  () {
    final found = find.byType(RawImage).evaluate();
    return found.isNotEmpty &&
        (found.first.widget as RawImage).image != null;
  },
  what: '图片显示出来',
);

void main() {
  group('文案', () {
    test('失败原因各有一句互不相同的中文人话', () {
      final texts = {
        for (final code in _codes) code: fileTransferErrorText(code),
      };
      expect(texts.values.toSet(), hasLength(_codes.length));
      for (final text in texts.values) {
        expect(text.endsWith('。'), isTrue);
      }
      expect(texts['too-large'], '文件太大，不能超过 100 MB。');
      expect(texts['network'], '网络出错，请稍后重试。');
      expect(texts['not-found'], contains(kOneTimeDownloadNotice));
      expect(texts['corrupt'], '文件在传输中损坏，无法保存。');
      expect(texts['changed'], '源文件在上传过程中被改动或无法读取。');
      expect(texts['rejected'], '中继拒绝了这次传输。');
      expect(texts['failed'], '传输失败，请稍后重试。');
      expect(fileTransferErrorText(null), texts['failed']);
      expect(fileTransferErrorText('other'), texts['failed']);
      expect(fileTransferErrorText('too-large-direct'), '文件太大，不能超过 100 GB。');
      expect(fileTransferErrorText('offline'), '对方不在线，无法点对点直传。');
      expect(fileTransferErrorText('no-direct'), contains('不能经过语音中继'));
      expect(fileTransferErrorText('busy'), '对方正忙，请稍后再试。');
      expect(fileTransferErrorText('declined'), '对方拒绝了这次文件传输。');
      expect(fileTransferErrorText('timeout'), '对方没有接受这次传输。');
    });

    test('文件大小写成短的可读形式', () {
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(-1), '0 B');
      expect(formatFileSize(800), '800 B');
      expect(formatFileSize(1024), '1.0 KB');
      expect(formatFileSize(1536), '1.5 KB');
      expect(formatFileSize(10 * 1024), '10 KB');
      expect(formatFileSize(1024 * 1024), '1.0 MB');
      expect(formatFileSize(12 * 1024 * 1024), '12 MB');
      expect(formatFileSize(1024 * 1024 * 1024), '1.0 GB');
      expect(formatFileSize(1536 * 1024 * 1024), '1.5 GB');
      expect(formatFileSize(12 * 1024 * 1024 * 1024), '12 GB');
    });

    test('中转确认和无法中转的说明', () {
      final confirm = relayConfirmBody(reason: 'offline', size: 2 * 1024 * 1024);
      expect(confirm, contains('对方现在不在线'));
      expect(confirm, contains('最多保留 7 天'));
      expect(confirm, contains('2.0 MB'));
      expect(confirm, contains('100 MB'));
      expect(relayConfirmBody(reason: 'no-direct', size: 10), contains('当前没有点对点直连'));

      final denied = relayUnavailableBody(reason: 'offline', size: 200 * 1024 * 1024);
      expect(denied, contains('对方现在不在线'));
      expect(denied, contains('200 MB'));
      expect(denied, contains('超过 100 MB'));
      expect(relayUnavailableBody(reason: 'no-direct', size: 200 * 1024 * 1024), contains('当前没有点对点直连'));
    });
  });

  group('文件部件', () {
    testWidgets('上传中显示进度，失败显示原因并可关闭', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        _wrap(
          FileUploadTile(
            name: '报告.pdf',
            done: 512 * 1024,
            total: 1024 * 1024,
            onCancel: () => cancelled = true,
          ),
        ),
      );
      expect(find.textContaining('正在发送 报告.pdf'), findsOneWidget);
      expect(find.text('512 KB / 1.0 MB'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      expect(cancelled, isTrue);

      cancelled = false;
      await tester.pumpWidget(
        _wrap(
          FileUploadTile(
            name: '报告.pdf',
            done: 0,
            total: 10,
            error: 'network',
            onCancel: () => cancelled = true,
          ),
        ),
      );
      expect(find.text('发送失败：报告.pdf'), findsOneWidget);
      expect(find.text('网络出错，请稍后重试。'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      expect(cancelled, isTrue);
    });

    testWidgets('直传上传显示双方需在线的说明', (tester) async {
      await tester.pumpWidget(
        _wrap(
          FileUploadTile(
            name: '电影.mkv',
            done: 0,
            total: 2 * 1024 * 1024 * 1024,
            isDirect: true,
            onCancel: () {},
          ),
        ),
      );
      expect(find.text(kDirectTransferNotice), findsOneWidget);
      expect(find.text('0 B / 2.0 GB'), findsOneWidget);
    });

    testWidgets('来传待接受时显示说明和接受/拒绝', (tester) async {
      var accepted = false;
      var declined = false;
      await tester.pumpWidget(
        _wrap(
          FileIncomingTile(
            name: '电影.mkv',
            size: 2 * 1024 * 1024 * 1024,
            done: 0,
            total: 2 * 1024 * 1024 * 1024,
            needsAccept: true,
            onAccept: () => accepted = true,
            onDecline: () => declined = true,
          ),
        ),
      );
      expect(find.text(kDirectIncomingNotice), findsOneWidget);
      expect(find.textContaining('收到文件 电影.mkv'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '接受'));
      expect(accepted, isTrue);
      await tester.tap(find.widgetWithText(TextButton, '拒绝'));
      expect(declined, isTrue);
    });

    testWidgets('已在本机的图片只显示图片，不带文件名和「已保存」', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const FileMessageBody(
            name: 'whisper-paste-1.png',
            size: 2048,
            isSent: false,
            localPath: '/tmp/whisper-paste-1.png',
          ),
        ),
      );
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('whisper-paste-1.png'), findsNothing);
      expect(find.text('已保存'), findsNothing);
      expect(find.byIcon(Icons.insert_drive_file_outlined), findsNothing);
    });

    testWidgets('图片气泡右键菜单可以复制和另存', (tester) async {
      final calls = <String>[];
      final dir = Directory.systemTemp.createTempSync('whisper_img_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/whisper-paste-1.png';
      File(path).writeAsBytesSync(_png);
      await tester.pumpWidget(
        _wrap(
          FileMessageBody(
            name: 'whisper-paste-1.png',
            size: 2048,
            isSent: false,
            localPath: path,
            onCopyImage: () => calls.add('copy'),
            onSaveImage: () => calls.add('save'),
          ),
        ),
      );
      await _pumpUntilImageShown(tester);
      await tester.tap(find.byType(Image), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text(kCopyImageLabel), findsOneWidget);
      expect(find.text(kSaveImageLabel), findsOneWidget);
      await tester.tap(find.text(kCopyImageLabel));
      await tester.pumpAndSettle();
      expect(calls, ['copy']);

      await tester.tap(find.byType(Image), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text(kSaveImageLabel));
      await tester.pumpAndSettle();
      expect(calls, ['copy', 'save']);
    });

    testWidgets('点开大图后下方有复制和另存按钮', (tester) async {
      final calls = <String>[];
      final dir = Directory.systemTemp.createTempSync('whisper_img_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/whisper-paste-1.png';
      File(path).writeAsBytesSync(_png);
      await tester.pumpWidget(
        _wrap(
          FileMessageBody(
            name: 'whisper-paste-1.png',
            size: 2048,
            isSent: false,
            localPath: path,
            onCopyImage: () => calls.add('copy'),
            onSaveImage: () => calls.add('save'),
          ),
        ),
      );
      await _pumpUntilImageShown(tester);
      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, kCopyImageLabel));
      await tester.tap(find.widgetWithText(TextButton, kSaveImageLabel));
      await tester.pump();
      expect(calls, ['copy', 'save']);
    });

    testWidgets('还没收到本机的图片仍按文件显示', (tester) async {
      await tester.pumpWidget(
        _wrap(
          FileMessageBody(
            name: 'photo.png',
            size: 2048,
            isSent: false,
            onDownload: () {},
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('photo.png'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '下载'), findsOneWidget);
    });

    testWidgets('本机文件已不在的图片不显示图片', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const FileMessageBody(
            name: 'photo.png',
            size: 2048,
            isSent: true,
            localPath: '/tmp/gone.png',
            localMissing: true,
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('photo.png'), findsOneWidget);
    });

    testWidgets('直传文件气泡不出现中转下载提示', (tester) async {
      await tester.pumpWidget(
        _wrap(
          FileMessageBody(
            name: '电影.mkv',
            size: 2 * 1024 * 1024 * 1024,
            isSent: false,
            isDirect: true,
            localMissing: true,
          ),
        ),
      );
      expect(find.text(kDirectLocalMissing), findsOneWidget);
      expect(find.text(kOneTimeDownloadNotice), findsNothing);
      expect(find.widgetWithText(TextButton, '下载'), findsNothing);
    });

    testWidgets('文件气泡：下载说明、已保存、失败原因、本地文件丢失', (tester) async {
      await tester.pumpWidget(
        _wrap(
          FileMessageBody(
            name: '报告.pdf',
            size: 2048,
            isSent: false,
            onDownload: () {},
          ),
        ),
      );
      expect(find.text('报告.pdf'), findsOneWidget);
      expect(find.text('2.0 KB'), findsOneWidget);
      expect(find.text(kOneTimeDownloadNotice), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);

      await tester.pumpWidget(
        _wrap(
          FileMessageBody(
            name: '报告.pdf',
            size: 2048,
            isSent: false,
            localPath: '/tmp/报告.pdf',
            onReveal: () {},
          ),
        ),
      );
      expect(find.text('已保存'), findsOneWidget);
      expect(find.text('打开所在位置'), findsOneWidget);
      expect(find.text('下载'), findsNothing);

      await tester.pumpWidget(
        _wrap(
          FileMessageBody(
            name: '报告.pdf',
            size: 2048,
            isSent: false,
            localPath: '/tmp/报告.pdf',
            localMissing: true,
          ),
        ),
      );
      expect(find.text(kLocalFileMissing), findsOneWidget);
      expect(find.text('下载'), findsNothing);

      await tester.pumpWidget(
        _wrap(
          FileMessageBody(
            name: '报告.pdf',
            size: 2048,
            isSent: true,
            localPath: '/tmp/报告.pdf',
            localMissing: true,
          ),
        ),
      );
      expect(find.text(kSourceFileMissing), findsOneWidget);

      for (final code in _codes) {
        await tester.pumpWidget(
          _wrap(
            FileMessageBody(
              name: '报告.pdf',
              size: 2048,
              isSent: false,
              downloadError: code,
              onRetry: () {},
              onDismiss: () {},
            ),
          ),
        );
        expect(find.text(fileTransferErrorText(code)), findsOneWidget);
        expect(find.text(kOneTimeDownloadNotice), findsWidgets);
        expect(find.text('重试'), findsOneWidget);
        expect(find.text('关闭'), findsOneWidget);
      }

      await tester.pumpWidget(
        _wrap(
          FileMessageBody(
            name: '报告.pdf',
            size: 3 * 1024 * 1024,
            isSent: false,
            downloadDone: 1024 * 1024,
            downloadTotal: 3 * 1024 * 1024,
            onCancelDownload: () {},
          ),
        ),
      );
      expect(find.text('1.0 MB / 3.0 MB'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
      expect(find.text('下载'), findsNothing);
    });
  });

  group('ChatScreen 文件界面', () {
    late IdentityKeyPair alice;
    late IdentityKeyPair bob;
    late Contact bobContact;
    late FakeRelay relay;
    late FakeConnection connection;
    late MessagingService messaging;
    late FakeFileRelay fileRelay;
    late FileRelayTransfer transfer;
    late FileShareService files;
    late Directory dir;
    late _FakePicker picker;
    late List<String> revealed;
    late List<String> copied;

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
      await Future<void>.delayed(const Duration(milliseconds: 30));

      fileRelay = FakeFileRelay();
      transfer = FileRelayTransfer(fileRelay, retryDelay: Duration.zero);
      files = FileShareService(messaging: messaging, transfer: transfer);
      dir = await Directory.systemTemp.createTemp('whisper_file_ui_');
      picker = _FakePicker();
      revealed = [];
      copied = [];
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

    Future<void> fromBob(
      String id,
      ChatContent content, {
      int ts = 5000,
    }) async {
      final payload = await MessageCodec.seal(
        key: await bobKey(),
        sessionId: _sessionId,
        senderRole: 'b',
        messageId: id,
        content: content,
      );
      connection.push({'type': 'msg', 'id': id, 'payload': payload, 'ts': ts});
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    Future<({FileOffer offer, File file})> bobUploads(
      int size, [
      String name = 'from-bob.bin',
    ]) async {
      final file = await source(size, name);
      final offer = await transfer.upload(file, auth: _auth);
      fileRelay.calls.clear();
      return (offer: offer, file: file);
    }

    Future<ChatMessage> receivedFile(
      int size, {
      String id = 'in-file',
      String name = 'from-bob.bin',
    }) async {
      final up = await bobUploads(size, name);
      await fromBob(id, ChatContent.file(up.offer.encode(), sentAt: 1));
      return (await messaging.messages(bobContact)).single;
    }

    Future<void> pumpChat(WidgetTester tester, {Contact? contact}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: ChatScreen(
            key: UniqueKey(),
            contactName: 'Bob',
            contact: contact ?? bobContact,
            messaging: messaging,
            files: files,
            filePicker: picker,
            revealFile: (path) async => revealed.add(path),
            copyImage: (path) async {
              copied.add(path);
              return true;
            },
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
        what: '聊天界面加载完',
      );
    }

    Future<T> real<T>(WidgetTester tester, Future<T> Function() action) async {
      final result = await tester.runAsync(action);
      if (result is! T) fail('runAsync 没有返回预期结果');
      return result;
    }

    testWidgets('阅后即焚开启时禁用发文件并给出说明', (tester) async {
      await pumpChat(tester, contact: bobContact.copyWith(burnAfterRead: true));
      expect(find.byTooltip(kBurnDisablesFileSend), findsOneWidget);
      final button = tester.widget<TermIconButton>(
        find.widgetWithIcon(TermIconButton, Icons.attach_file),
      );
      expect(button.onPressed, isNull);
      expect(find.byTooltip('发送文件'), findsNothing);
    });

    testWidgets('选文件发送：进度、取消后不出现文件消息', (tester) async {
      final file = await real(
        tester,
        () => source(2 * FileCipher.chunkSize, '相册.zip'),
      );
      picker.source = file.path;
      final gate = Completer<void>();
      fileRelay.before = (op, index) async {
        if (op == 'put' && index == 1) await gate.future;
      };

      await pumpChat(tester);
      await tester.tap(find.byTooltip('发送文件'));
      await _pumpUntil(
        tester,
        () => find.text(kRelayConfirmTitle).evaluate().isNotEmpty,
        what: '中转确认弹窗',
      );
      await tester.tap(find.widgetWithText(FilledButton, kRelayConfirmSend));
      await _pumpUntil(
        tester,
        () => find.textContaining('正在发送 相册.zip').evaluate().isNotEmpty,
        what: '上传进度',
      );
      expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pump();
      await tester.runAsync(() async => gate.complete());
      await _pumpUntil(
        tester,
        () => find.textContaining('正在发送').evaluate().isEmpty,
        what: '取消后上传条消失',
      );
      expect(find.text('相册.zip'), findsNothing);
      expect(await real(tester, () => messaging.messages(bobContact)), isEmpty);
    });

    testWidgets('上传失败显示原因，关闭后消失；成功后出现已保存的文件气泡', (tester) async {
      // 用不会重试的拒绝，避免 Future.delayed 重试卡在 FakeAsync 里。
      fileRelay.before = (op, index) async {
        if (op == 'put') throw const FileRelayException(400, 'nope');
      };
      final failed = await real(tester, () => source(10, '失败.bin'));
      picker.source = failed.path;

      await pumpChat(tester);
      picker.source = failed.path;
      await tester.runAsync(() => files.sendViaRelay(bobContact, failed));
      await tester.pump();
      expect(find.text('发送失败：失败.bin'), findsOneWidget);
      expect(find.text('中继拒绝了这次传输。'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pump();
      await _pumpUntil(
        tester,
        () => find.text('发送失败：失败.bin').evaluate().isEmpty,
        what: '关闭失败记录',
      );

      fileRelay.before = null;
      final ok = await real(tester, () => source(10, '成功.bin'));
      await tester.runAsync(() => files.sendViaRelay(bobContact, ok));
      await tester.pump();
      await _pumpUntil(
        tester,
        () => find.text('成功.bin').evaluate().isNotEmpty,
        what: '发出的文件消息',
      );
      expect(find.text('已保存'), findsOneWidget);

      await tester.tap(find.text('打开所在位置'));
      await tester.pump();
      expect(revealed, [ok.absolute.path]);
    });

    testWidgets('图片消息：右键复制、另存为拷到所选位置', (tester) async {
      final image = File('${dir.path}/截图.png')..writeAsBytesSync(_png);
      await pumpChat(tester);
      await tester.runAsync(() => files.sendViaRelay(bobContact, image));
      await _pumpUntilImageShown(tester);

      await tester.tap(find.byType(Image), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text(kCopyImageLabel));
      await _pumpUntil(
        tester,
        () => find.text('已复制图片').evaluate().isNotEmpty,
        what: '复制成功提示',
      );
      expect(copied, [image.absolute.path]);

      final target = File('${dir.path}/另存.png');
      picker.savePath = target.path;
      await tester.tap(find.byType(Image), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text(kSaveImageLabel));
      await _pumpUntil(
        tester,
        () => target.existsSync(),
        what: '图片另存完成',
      );
      expect(picker.suggested.last, '截图.png');
      expect(target.readAsBytesSync(), image.readAsBytesSync());

      // 用户取消保存对话框：什么都不做
      picker.savePath = null;
      await tester.tap(find.byType(Image), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text(kSaveImageLabel));
      await tester.pumpAndSettle();
      expect(picker.suggested, hasLength(2));
    });

    testWidgets('收到的文件：下载前说明、进度、根据 updates 刷新为已保存', (tester) async {
      await real(
        tester,
        () => receivedFile(2 * FileCipher.chunkSize + 7, name: '来自对方.bin'),
      );
      picker.savePath = '${dir.path}/saved.bin';
      final gate = Completer<void>();
      fileRelay.before = (op, index) async {
        if (op == 'get' && index == 1) await gate.future;
      };

      await pumpChat(tester);
      expect(find.text('来自对方.bin'), findsOneWidget);
      expect(find.text(kOneTimeDownloadNotice), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);

      await tester.tap(find.text('下载'));
      await _pumpUntil(
        tester,
        () => find.widgetWithText(TextButton, '取消').evaluate().isNotEmpty,
        what: '下载进度',
      );
      expect(find.text('下载'), findsNothing);
      expect(find.textContaining(' / '), findsOneWidget);

      fileRelay.before = null;
      await tester.runAsync(() async => gate.complete());
      await _pumpUntil(
        tester,
        () => find.text('已保存').evaluate().isNotEmpty,
        what: '下载完成',
      );
      expect(find.text('打开所在位置'), findsOneWidget);
      final saved = await real(
        tester,
        () => File(picker.savePath!).readAsBytes(),
      );
      final original = await real(
        tester,
        () => File('${dir.path}/来自对方.bin').readAsBytes(),
      );
      expect(saved, original);
    });

    testWidgets('保存目标已存在时确认是否覆盖；取消则不下载', (tester) async {
      await real(tester, () => receivedFile(10));
      final existing = File('${dir.path}/exists.bin');
      await real(
        tester,
        () => existing.writeAsBytes(const [1, 2, 3], flush: true),
      );
      picker.savePath = existing.path;

      await pumpChat(tester);
      await tester.tap(find.text('下载'));
      await _pumpUntil(
        tester,
        () => find.text('文件已存在').evaluate().isNotEmpty,
        what: '覆盖确认',
      );
      expect(find.textContaining('已经存在，要覆盖吗？'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await _pumpUntil(
        tester,
        () => find.text('文件已存在').evaluate().isEmpty,
        what: '关掉覆盖确认',
      );
      expect(await real(tester, () => existing.readAsBytes()), [1, 2, 3]);
      expect(find.text('下载'), findsOneWidget);
      expect(files.downloadState('in-file'), isNull);

      await tester.tap(find.text('下载'));
      await _pumpUntil(
        tester,
        () => find.text('覆盖').evaluate().isNotEmpty,
        what: '再次覆盖确认',
      );
      await tester.tap(find.widgetWithText(FilledButton, '覆盖'));
      await _pumpUntil(
        tester,
        () => find.text('已保存').evaluate().isNotEmpty,
        what: '覆盖后下载完成',
      );
      expect(await real(tester, () => existing.length()), 10);
    });

    testWidgets('保存默认文件名用 safeName，不用 offer.name', (tester) async {
      final up = await real(tester, () => bobUploads(10, 'ok.bin'));
      final evil = FileOffer(
        fileId: up.offer.fileId,
        name: r'../evil/..\bad?.txt',
        size: up.offer.size,
        keys: up.offer.keys,
        hash: up.offer.hash,
      );
      await tester.runAsync(
        () => fromBob('in-evil', ChatContent.file(evil.encode(), sentAt: 1)),
      );
      picker.savePath = '${dir.path}/bad.txt';

      await pumpChat(tester);
      expect(find.text('bad.txt'), findsOneWidget);
      expect(find.textContaining('evil'), findsNothing);
      expect(find.text(r'../evil/..\bad?.txt'), findsNothing);

      await tester.tap(find.text('下载'));
      await _pumpUntil(
        tester,
        () => picker.suggested.isNotEmpty,
        what: '打开保存对话框',
      );
      expect(picker.suggested, ['bad.txt']);
    });

    testWidgets('下载失败显示原因并可关掉；本地记录在但文件不在时不能再下', (tester) async {
      fileRelay.before = (op, index) async {
        if (op == 'get') throw const FileRelayException(404, 'not-found');
      };
      await real(tester, () => receivedFile(10, id: 'gone'));
      picker.savePath = '${dir.path}/gone.bin';

      await pumpChat(tester);
      await tester.tap(find.text('下载'));
      await _pumpUntil(
        tester,
        () =>
            find.text(fileTransferErrorText('not-found')).evaluate().isNotEmpty,
        what: '下载失败原因',
      );
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await _pumpUntil(
        tester,
        () => find.text(fileTransferErrorText('not-found')).evaluate().isEmpty,
        what: '关掉失败记录',
      );
      expect(find.text('下载'), findsOneWidget);

      final missing = '${dir.path}/missing-local.bin';
      await tester.runAsync(() => LocalDatabase.setFilePath('gone', missing));
      final paths = await real(tester, () => files.localPaths(_sessionId));
      expect(paths['gone'], missing);

      await pumpChat(tester);
      expect(find.text(kLocalFileMissing), findsOneWidget);
      expect(find.text('下载'), findsNothing);
    });

    testWidgets('对方离线时取消中转确认则不发送', (tester) async {
      final file = await real(tester, () => source(10, '取消.bin'));
      picker.source = file.path;
      await pumpChat(tester);
      await tester.tap(find.byTooltip('发送文件'));
      await _pumpUntil(
        tester,
        () => find.text(kRelayConfirmTitle).evaluate().isNotEmpty,
        what: '中转确认弹窗',
      );
      expect(find.textContaining('对方现在不在线'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(find.text(kRelayConfirmTitle), findsNothing);
      expect(find.textContaining('正在发送'), findsNothing);
      expect(fileRelay.files, isEmpty);
      expect(await real(tester, () => messaging.messages(bobContact)), isEmpty);
    });

    testWidgets('取消选文件则什么都不做', (tester) async {
      picker.source = null;
      await pumpChat(tester);
      await tester.tap(find.byTooltip('发送文件'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('正在发送'), findsNothing);
      expect(find.text('暂无消息'), findsOneWidget);
      expect(picker.sourceCalls, 1);
    });
  });
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(
      body: Center(child: SizedBox(width: 400, child: child)),
    ),
  );
}

Future<void> _until(bool Function() condition, {String what = '条件'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _FakePicker implements FileLocationPicker {
  String? source;
  String? savePath;
  final List<String> suggested = [];
  int sourceCalls = 0;

  @override
  Future<String?> pickSource() async {
    sourceCalls++;
    return source;
  }

  @override
  Future<String?> pickSavePath({required String suggestedName}) async {
    suggested.add(suggestedName);
    return savePath;
  }
}
