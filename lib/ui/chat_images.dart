/// 聊天里的图片消息：根据文件名判断是否当作图片内联显示。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_theme.dart';

export '../files/image_file.dart' show isImageFileName, isVideoFileName;

/// 把剪贴板图片存成临时文件时用的扩展名；不认识的按 png。
String clipboardImageExtension(String format) {
  final lower = format.toLowerCase();
  if (lower.contains('jpeg') || lower.contains('jpg')) return 'jpg';
  if (lower.contains('gif')) return 'gif';
  if (lower.contains('webp')) return 'webp';
  if (lower.contains('bmp')) return 'bmp';
  return 'png';
}

/// [bytes] 是否以 PNG 文件头开始。
bool isPngBytes(List<int> bytes) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  return true;
}

/// 把一张图片转成 PNG：已经是 PNG 的原样返回，其它格式解码后重新编码（动图只取第一帧）。
/// 解码不了时抛异常。
Future<Uint8List> imageBytesAsPng(Uint8List bytes) async {
  if (isPngBytes(bytes)) return bytes;
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('无法编码为 PNG');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// 图片右键菜单和大图下方按钮的文字。
const String kCopyImageLabel = '复制图片';
const String kSaveImageLabel = '另存为…';

/// 在 [position]（全局坐标）弹出图片的右键菜单。
Future<void> showChatImageMenu(
  BuildContext context,
  Offset position, {
  VoidCallback? onCopy,
  VoidCallback? onSave,
}) async {
  await showTermMenuAt(context, position, [
    if (onCopy != null) (kCopyImageLabel, onCopy),
    if (onSave != null) (kSaveImageLabel, onSave),
  ]);
}

/// 在 [position]（全局坐标）弹出一个菜单，每项是（文字，点了做什么）。没有项时不弹。
Future<void> showTermMenuAt(
  BuildContext context,
  Offset position,
  List<(String, VoidCallback)> items,
) async {
  if (items.isEmpty) return;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final chosen = await showMenu<VoidCallback>(
    context: context,
    position: RelativeRect.fromRect(
      position & Size.zero,
      Offset.zero & overlay.size,
    ),
    items: [
      for (final (label, action) in items)
        PopupMenuItem(value: action, child: Text(label)),
    ],
  );
  chosen?.call();
}

/// 点击缩略图后放大查看；点图片关闭。图片下方可以复制或另存。
void showChatImagePreview(
  BuildContext context,
  String path, {
  VoidCallback? onCopy,
  VoidCallback? onSave,
}) {
  showTermDialog<void>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              onSecondaryTapUp: (details) => showChatImageMenu(
                context,
                details.globalPosition,
                onCopy: onCopy,
                onSave: onSave,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 720,
                  maxHeight: 640,
                ),
                child: InteractiveViewer(
                  child: Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('无法打开这张图片'),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text(
              '滚轮缩放 · 拖动平移 · 点图片或按 Esc 关闭',
              style: TextStyle(color: AppTheme.text3, fontSize: 11.5),
            ),
          ),
          if (onCopy != null || onSave != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onCopy != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: TextButton(
                        style: AppTheme.secondaryButton,
                        onPressed: onCopy,
                        child: const Text(kCopyImageLabel),
                      ),
                    ),
                  if (onSave != null)
                    TextButton(
                      onPressed: onSave,
                      child: const Text(kSaveImageLabel),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
