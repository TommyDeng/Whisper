/// 从系统剪贴板取出图片，写成文件，再走现有的发文件路径。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'chat_images.dart';

/// 从剪贴板读到的图片字节和格式名（png / jpeg / …）。
class ClipboardImageBytes {
  const ClipboardImageBytes({required this.bytes, required this.format});

  final Uint8List bytes;
  final String format;
}

/// 把图片写到 [directory]，文件名带时间戳。
Future<File> writeClipboardImageToTemp({
  required ClipboardImageBytes image,
  required Directory directory,
  DateTime? now,
}) async {
  final ext = clipboardImageExtension(image.format);
  final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final file = File('${directory.path}/whisper-paste-$stamp.$ext');
  await file.writeAsBytes(image.bytes, flush: true);
  return file;
}

/// 读系统剪贴板里的图片。没有图片或平台不支持时返回 null。
Future<ClipboardImageBytes?> readClipboardImageBytes() async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return null;
  final reader = await clipboard.read();
  const candidates = <(FileFormat, String)>[
    (Formats.png, 'png'),
    (Formats.jpeg, 'jpeg'),
    (Formats.gif, 'gif'),
    (Formats.webp, 'webp'),
    (Formats.bmp, 'bmp'),
  ];
  for (final candidate in candidates) {
    final format = candidate.$1;
    if (!reader.canProvide(format)) continue;
    final bytes = await _readFile(reader, format);
    if (bytes != null && bytes.isNotEmpty) {
      return ClipboardImageBytes(bytes: bytes, format: candidate.$2);
    }
  }
  return null;
}

/// 有图片就写成临时文件，没有则返回 null。
Future<File?> saveClipboardImage({Directory? directory}) async {
  final image = await readClipboardImageBytes();
  if (image == null) return null;
  final dir = directory ?? await getTemporaryDirectory();
  return writeClipboardImageToTemp(image: image, directory: dir);
}

Future<Uint8List?> _readFile(ClipboardReader reader, FileFormat format) {
  final done = Completer<Uint8List?>();
  final progress = reader.getFile(
    format,
    (file) async {
      try {
        done.complete(await file.readAll());
      } catch (_) {
        if (!done.isCompleted) done.complete(null);
      }
    },
    onError: (_) {
      if (!done.isCompleted) done.complete(null);
    },
  );
  if (progress == null) return Future<Uint8List?>.value(null);
  return done.future;
}
