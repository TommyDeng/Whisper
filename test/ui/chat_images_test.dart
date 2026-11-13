import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/ui/chat_images.dart';
import 'package:whisper/ui/clipboard_image.dart';
import 'package:whisper/ui/about.dart';

void main() {
  group('图片文件名', () {
    test('按扩展名识别常见图片，忽略大小写', () {
      expect(isImageFileName('photo.PNG'), isTrue);
      expect(isImageFileName('a.jpg'), isTrue);
      expect(isImageFileName('a.jpeg'), isTrue);
      expect(isImageFileName('a.gif'), isTrue);
      expect(isImageFileName('a.webp'), isTrue);
      expect(isImageFileName('a.bmp'), isTrue);
      expect(isImageFileName('notes.txt'), isFalse);
      expect(isImageFileName('noext'), isFalse);
      expect(isImageFileName('a.'), isFalse);
    });

    test('剪贴板格式落到扩展名', () {
      expect(clipboardImageExtension('image/png'), 'png');
      expect(clipboardImageExtension('jpeg'), 'jpg');
      expect(clipboardImageExtension('image/gif'), 'gif');
      expect(clipboardImageExtension('unknown'), 'png');
    });
  });

  group('转成 PNG', () {
    // 1x1 的 GIF 和 PNG
    final gif = base64Decode(
      'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
    );
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
      'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );

    test('识别 PNG 文件头', () {
      expect(isPngBytes(png), isTrue);
      expect(isPngBytes(gif), isFalse);
      expect(isPngBytes(const [0x89, 0x50]), isFalse);
    });

    testWidgets('PNG 原样返回，其它格式重新编码成 PNG', (tester) async {
      await tester.runAsync(() async {
        expect(await imageBytesAsPng(png), same(png));
        final converted = await imageBytesAsPng(gif);
        expect(isPngBytes(converted), isTrue);
      });
    });

    testWidgets('不是图片时抛异常', (tester) async {
      await tester.runAsync(() async {
        await expectLater(
          imageBytesAsPng(Uint8List.fromList([1, 2, 3, 4])),
          throwsA(anything),
        );
      });
    });
  });

  group('剪贴板图片落盘', () {
    test('按格式写临时文件', () async {
      final dir = await Directory.systemTemp.createTemp('whisper-paste-test');
      addTearDown(() => dir.delete(recursive: true));
      final file = await writeClipboardImageToTemp(
        image: ClipboardImageBytes(
          bytes: Uint8List.fromList([1, 2, 3, 4]),
          format: 'image/jpeg',
        ),
        directory: dir,
        now: DateTime.utc(2026, 11, 12, 13, 14, 15),
      );
      expect(file.path.endsWith('.jpg'), isTrue);
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
    });
  });

  group('关于版本文案', () {
    test('拼出版本号和构建号', () {
      expect(formatAppVersion('1.0.3', '4'), '1.0.3（4）');
      expect(formatAppVersion('1.0.3', ''), '1.0.3');
      expect(formatAppVersion('', ''), '未知版本');
    });
  });
}
