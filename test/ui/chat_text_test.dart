import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/ui/app_theme.dart';
import 'package:whisper/ui/chat_text.dart';
import 'package:whisper/ui/file_transfer_ui.dart';

void main() {
  group('splitLinks', () {
    test('没有链接时整段是普通文字', () {
      expect(splitLinks('你好'), [const TextPiece('你好')]);
      expect(splitLinks(''), isEmpty);
    });

    test('认出 http、https 和 www. 开头的链接', () {
      expect(splitLinks('看 https://example.com/a?b=1 这个'), [
        const TextPiece('看 '),
        const TextPiece(
          'https://example.com/a?b=1',
          url: 'https://example.com/a?b=1',
        ),
        const TextPiece(' 这个'),
      ]);
      expect(splitLinks('www.example.com'), [
        const TextPiece('www.example.com', url: 'https://www.example.com'),
      ]);
      expect(splitLinks('HTTP://Example.com').single.url, 'HTTP://Example.com');
    });

    test('句末标点和中文标点不算进链接', () {
      expect(splitLinks('去 https://a.com/x. 吧')[1].text, 'https://a.com/x');
      expect(splitLinks('链接：https://a.com/x，然后')[1].text, 'https://a.com/x');
      expect(splitLinks('(see https://a.com/x)')[1].text, 'https://a.com/x');
      expect(
        splitLinks('https://en.wikipedia.org/wiki/A_(b)').single.text,
        'https://en.wikipedia.org/wiki/A_(b)',
      );
    });

    test('不认别的协议，也不认只有前缀的', () {
      expect(splitLinks('javascript:alert(1)').any((p) => p.isLink), isFalse);
      expect(splitLinks('file:///etc/passwd').any((p) => p.isLink), isFalse);
      expect(splitLinks('https:// 后面没有').any((p) => p.isLink), isFalse);
    });

    test('多个链接都切出来，文字拼回去和原文一样', () {
      const text = 'a https://x.com b www.y.org/z c';
      final pieces = splitLinks(text);
      expect(pieces.where((p) => p.isLink).map((p) => p.url), [
        'https://x.com',
        'https://www.y.org/z',
      ]);
      expect(pieces.map((p) => p.text).join(), text);
    });
  });

  test('openExternalLink 只放行 http / https', () async {
    expect(await openExternalLink('javascript:alert(1)'), isFalse);
    expect(await openExternalLink('file:///etc/passwd'), isFalse);
  });

  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('点消息里的链接用浏览器打开', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(
      host(
        MessageText(
          'https://example.com',
          style: const TextStyle(fontSize: 14),
          linkColor: AppTheme.accent,
          openLink: (url) async {
            opened.add(url);
            return true;
          },
        ),
      ),
    );
    await tester.tap(find.byType(MessageText));
    await tester.pump();
    expect(opened, ['https://example.com']);
  });

  testWidgets('右键链接：菜单里有打开链接、复制链接、复制、全选', (tester) async {
    final opened = <String>[];
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      host(
        MessageText(
          'https://example.com',
          style: const TextStyle(fontSize: 14),
          linkColor: AppTheme.accent,
          openLink: (url) async {
            opened.add(url);
            return true;
          },
        ),
      ),
    );
    final center = tester.getCenter(find.byType(MessageText));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: center);
    await mouse.moveTo(center);
    await tester.pump();
    final right = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await right.up();
    await tester.pump(const Duration(milliseconds: 300));

    for (final label in [
      kOpenLinkLabel,
      kCopyLinkLabel,
      kCopyLabel,
      kSelectAllLabel,
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text(kCopyLinkLabel));
    await tester.pump(const Duration(milliseconds: 300));
    expect(copied, 'https://example.com');
    expect(opened, isEmpty);
  });

  testWidgets('右键普通文字：没有链接选项，复制整条消息', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      host(
        const MessageText(
          '你好啊',
          style: TextStyle(fontSize: 14),
          linkColor: AppTheme.accent,
        ),
      ),
    );
    final right = await tester.startGesture(
      tester.getCenter(find.byType(MessageText)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await right.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(kOpenLinkLabel), findsNothing);
    // 右键会先选中一个词；「全选」后再复制，拿到整条。
    await tester.tap(find.text(kSelectAllLabel));
    await tester.pump(const Duration(milliseconds: 300));
    // 全选后菜单可能还开着；收起了就再右键一次。
    if (find.text(kCopyLabel).evaluate().isEmpty) {
      final again = await tester.startGesture(
        tester.getCenter(find.byType(MessageText)),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await again.up();
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text(kCopyLabel));
    await tester.pump(const Duration(milliseconds: 300));
    expect(copied, '你好啊');
  });

  testWidgets('已在本机的视频画成卡片，点了用系统播放器打开', (tester) async {
    var played = 0;
    await tester.pumpWidget(
      host(
        FileMessageBody(
          name: '旅行.mp4',
          size: 1024,
          isSent: false,
          localPath: '/tmp/旅行.mp4',
          onOpen: () => played++,
        ),
      ),
    );
    expect(find.byType(VideoMessageCard), findsOneWidget);
    await tester.tap(find.byType(VideoMessageCard));
    await tester.pump(const Duration(milliseconds: 300));
    expect(played, 1);
  });

  testWidgets('还没下载的视频仍是文件卡，图标是视频', (tester) async {
    await tester.pumpWidget(
      host(
        FileMessageBody(
          name: '旅行.mp4',
          size: 1024,
          isSent: false,
          onDownload: () {},
        ),
      ),
    );
    expect(find.byType(VideoMessageCard), findsNothing);
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
  });
}
