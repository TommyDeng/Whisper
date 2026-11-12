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
