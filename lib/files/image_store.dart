/// 聊天图片在本机的存放处：粘贴发出的图片和自动接收的图片都放这里。
///
/// 和聊天记录同一个保留期：消息 7 天后删除，图片文件也跟着清掉。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ChatImageStore {
  ChatImageStore({Future<Directory> Function()? root})
    : _root = root ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _root;

  /// 图片目录；不存在就建出来。
  Future<Directory> directory() async {
    final dir = Directory(p.join((await _root()).path, 'chat-images'));
    await dir.create(recursive: true);
    return dir;
  }

  /// 删除修改时间早于 [retention] 之前的图片。
  Future<void> prune({
    Duration retention = const Duration(days: 7),
    DateTime? now,
  }) async {
    final cutoff = (now ?? DateTime.now()).subtract(retention);
    try {
      final dir = await directory();
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        try {
          if ((await entry.lastModified()).isBefore(cutoff)) {
            await entry.delete();
          }
        } on FileSystemException {
          // 删不掉的留到下次
        }
      }
    } on FileSystemException {
      // 目录不可用时没有可清的
    }
  }

  /// 删除全部图片（清除本机全部数据时调用）。
  Future<void> clear() async {
    try {
      final dir = await directory();
      await dir.delete(recursive: true);
    } on FileSystemException {
      // 没有目录就没有可删的
    }
  }
}
