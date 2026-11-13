/// 聊天里的图片消息：根据文件名判断是否当作图片内联显示。
library;

import 'dart:io';

import 'package:flutter/material.dart';

export '../files/image_file.dart' show isImageFileName;

/// 把剪贴板图片存成临时文件时用的扩展名；不认识的按 png。
String clipboardImageExtension(String format) {
  final lower = format.toLowerCase();
  if (lower.contains('jpeg') || lower.contains('jpg')) return 'jpg';
  if (lower.contains('gif')) return 'gif';
  if (lower.contains('webp')) return 'webp';
  if (lower.contains('bmp')) return 'bmp';
  return 'png';
}

/// 点击缩略图后放大查看；再点一次关闭。
void showChatImagePreview(BuildContext context, String path) {
  showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
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
  );
}
