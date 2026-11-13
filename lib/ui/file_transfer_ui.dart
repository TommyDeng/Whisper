/// 聊天里的文件发送、进度和保存界面。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_theme.dart';
import 'chat_images.dart';

/// 下载前和下载失败时展示的说明。
const String kOneTimeDownloadNotice = '一个文件只能成功下载一次，下载后中继上就删了。';

/// 阅后即焚开启时，发文件按钮上的说明。
const String kBurnDisablesFileSend = '阅后即焚开启时不能发文件。文件消息不支持阅后即焚。';

/// 本地已保存过、但磁盘上的文件已经不在时的说明（收到的文件不能再下一次）。
const String kLocalFileMissing = '本地文件已不在原来的位置。一个文件只能成功下载一次，无法再从中继下载。';

/// 自己发出的文件，源文件已经不在原来的位置。
const String kSourceFileMissing = '源文件已不在原来的位置。';

/// 大文件直传进行中的说明。
const String kDirectTransferNotice = '正在直传，请双方保持在线。文件不经服务器中转。';

/// 收到直传请求时的说明。
const String kDirectIncomingNotice = '对方要向你发送一个文件。双方必须同时在线，文件走点对点直连，不会经过服务器中转。';

/// 直传文件本地已经不在时的说明。
const String kDirectLocalMissing = '本地文件已不在原来的位置。大文件不会存在服务器上，无法再次下载。';

/// 把传输失败原因变成一句中文人话。未知原因按 [failed] 处理。
String fileTransferErrorText(String? code) {
  return switch (code) {
    'too-large' => '文件太大，不能超过 100 MB。',
    'too-large-direct' => '文件太大，不能超过 100 GB。',
    'offline' => '对方不在线，无法点对点直传。',
    'no-direct' => '当前没有点对点直连（只通了中继），文件不能经过语音中继传输。',
    'busy' => '对方正忙，请稍后再试。',
    'declined' => '对方拒绝了这次文件传输。',
    'timeout' => '对方没有接受这次传输。',
    'network' => '网络出错，请稍后重试。',
    'not-found' => '文件已过期或已被下载过。$kOneTimeDownloadNotice',
    'corrupt' => '文件在传输中损坏，无法保存。',
    'changed' => '源文件在上传过程中被改动或无法读取。',
    'rejected' => '中继拒绝了这次传输。',
    'failed' || _ => '传输失败，请稍后重试。',
  };
}

/// 把字节数写成短的可读大小，例如 `800 B`、`1.5 KB`、`12 MB`。
String formatFileSize(int bytes) {
  final n = bytes < 0 ? 0 : bytes;
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${_oneDecimal(n / 1024)} KB';
  if (n < 1024 * 1024 * 1024) return '${_oneDecimal(n / (1024 * 1024))} MB';
  return '${_oneDecimal(n / (1024 * 1024 * 1024))} GB';
}

String _oneDecimal(double value) =>
    value >= 10 ? value.round().toString() : value.toStringAsFixed(1);

/// 选要发送的文件，或选下载保存位置。
///
/// 正式环境用 [DesktopFileLocationPicker]（系统对话框）；测试里换成假的。
abstract class FileLocationPicker {
  Future<String?> pickSource();

  /// [suggestedName] 必须是对方文件消息的 safeName，不能用对方给的原始文件名。
  Future<String?> pickSavePath({required String suggestedName});
}

class DesktopFileLocationPicker implements FileLocationPicker {
  const DesktopFileLocationPicker();

  @override
  Future<String?> pickSource() async {
    final file = await openFile();
    final path = file?.path;
    if (path == null || path.isEmpty) return null;
    return path;
  }

  @override
  Future<String?> pickSavePath({required String suggestedName}) async {
    final location = await getSaveLocation(suggestedName: suggestedName);
    final path = location?.path;
    if (path == null || path.isEmpty) return null;
    return path;
  }
}

/// 在文件管理器里打开 [path] 所在的位置。
Future<void> revealFileInFolder(String path) async {
  if (Platform.isWindows) {
    await Process.start('explorer', ['/select,${p.normalize(path)}']);
  } else if (Platform.isLinux) {
    await Process.start('xdg-open', [p.dirname(path)]);
  } else if (Platform.isMacOS) {
    await Process.start('open', ['-R', path]);
  }
}

/// 目标已存在时询问是否覆盖。用户取消或关掉对话框返回 false。
Future<bool> confirmOverwrite(BuildContext context, String name) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('文件已存在'),
      content: Text('“$name”已经存在，要覆盖吗？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('覆盖'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 确认经服务器中转发送时的标题。
const String kRelayConfirmTitle = '经服务器发送？';

/// 确认按钮。
const String kRelayConfirmSend = '确认发送';

/// 无法中转时的标题。
const String kRelayUnavailableTitle = '无法发送';

/// 请用户确认后再走中转的说明。[reason] 为 `offline` 或 `no-direct`。
String relayConfirmBody({required String reason, required int size}) {
  final why = reason == 'no-direct' ? '当前没有点对点直连' : '对方现在不在线';
  return '$why。文件会先加密，再上传到服务器，最多保留 7 天，对方下载后删除。大小 ${formatFileSize(size)}（中转上限 100 MB）。确认发送吗？';
}

/// 不能走中转时的说明（超过 100 MiB）。
String relayUnavailableBody({required String reason, required int size}) {
  final why = reason == 'no-direct' ? '当前没有点对点直连' : '对方现在不在线';
  return '$why，且文件大小 ${formatFileSize(size)}，超过 100 MB 的中转上限，不能经过服务器发送。请在双方在线且可直连时再试。';
}

/// 询问是否经服务器中转发送。用户取消或关掉对话框返回 false。
Future<bool> confirmRelaySend(
  BuildContext context, {
  required String reason,
  required int size,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text(kRelayConfirmTitle),
      content: Text(relayConfirmBody(reason: reason, size: size)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text(kRelayConfirmSend),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 说明无法经服务器中转。
Future<void> showRelayUnavailable(
  BuildContext context, {
  required String reason,
  required int size,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text(kRelayUnavailableTitle),
      content: Text(relayUnavailableBody(reason: reason, size: size)),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

/// 还没有变成消息的上传（进行中或失败），画在输入栏上方。
class FileUploadTile extends StatelessWidget {
  const FileUploadTile({
    super.key,
    required this.name,
    required this.done,
    required this.total,
    this.error,
    this.isDirect = false,
    required this.onCancel,
  });

  final String name;
  final int done;
  final int total;
  final String? error;
  final bool isDirect;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final failed = error != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: failed ? AppTheme.red : AppTheme.lightGray),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    failed ? Icons.error_outline : Icons.upload_outlined,
                    size: 16,
                    color: failed ? AppTheme.red : AppTheme.darkGray,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      failed ? '发送失败：$name' : '正在发送 $name',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: failed ? AppTheme.red : AppTheme.black,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onCancel,
                    style: _compactButton(AppTheme.black),
                    child: Text(failed ? '关闭' : '取消'),
                  ),
                ],
              ),
              if (failed)
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 4),
                  child: Text(
                    fileTransferErrorText(error),
                    style: const TextStyle(color: AppTheme.red, fontSize: 12),
                  ),
                )
              else ...[
                if (isDirect)
                  const Padding(
                    padding: EdgeInsets.only(right: 8, bottom: 4),
                    child: Text(
                      kDirectTransferNotice,
                      style: TextStyle(color: AppTheme.darkGray, fontSize: 11),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
                  child: _ProgressLine(
                    done: done,
                    total: total,
                    color: AppTheme.black,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 文件消息气泡的正文（外层对齐和发送状态由 [ChatBubble] 负责）。
class FileMessageBody extends StatelessWidget {
  const FileMessageBody({
    super.key,
    required this.name,
    required this.size,
    required this.isSent,
    this.isDirect = false,
    this.localPath,
    this.localMissing = false,
    this.downloadDone,
    this.downloadTotal,
    this.downloadError,
    this.onDownload,
    this.onCancelDownload,
    this.onRetry,
    this.onDismiss,
    this.onReveal,
  });

  final String name;
  final int size;
  final bool isSent;
  final bool isDirect;
  final String? localPath;
  final bool localMissing;
  final int? downloadDone;
  final int? downloadTotal;
  final String? downloadError;
  final VoidCallback? onDownload;
  final VoidCallback? onCancelDownload;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;
  final VoidCallback? onReveal;

  @override
  Widget build(BuildContext context) {
    final fg = isSent ? AppTheme.white : AppTheme.black;
    final muted = isSent ? AppTheme.lightGray : AppTheme.darkGray;
    final failed = downloadError != null;
    final downloading =
        !failed && downloadTotal != null && onCancelDownload != null;
    final saved = localPath != null && !localMissing && !downloading && !failed;

    final showImage = saved && isImageFileName(name) && localPath != null;

    // 已经在本机的图片只显示图片本身，不再带文件名、大小和「已保存」。
    if (showImage) {
      return GestureDetector(
        onTap: () => showChatImagePreview(context, localPath!),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280, maxHeight: 320),
            child: Image.file(
              File(localPath!),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) => Text(
                '无法显示图片：$name',
                style: TextStyle(color: fg, fontSize: 14),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_outlined, size: 18, color: fg),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  Text(
                    formatFileSize(size),
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (downloading) ...[
          const SizedBox(height: 8),
          _ProgressLine(
            done: downloadDone ?? 0,
            total: downloadTotal!,
            color: fg,
            track: muted,
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onCancelDownload,
              style: _compactButton(fg),
              child: const Text('取消'),
            ),
          ),
        ] else if (failed) ...[
          const SizedBox(height: 6),
          Text(
            fileTransferErrorText(downloadError),
            style: const TextStyle(color: AppTheme.red, fontSize: 12),
          ),
          const SizedBox(height: 2),
          if (!isDirect)
            Text(
              kOneTimeDownloadNotice,
              style: TextStyle(color: muted, fontSize: 11),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onRetry != null)
                TextButton(
                  onPressed: onRetry,
                  style: _compactButton(fg),
                  child: const Text('重试'),
                ),
              if (onDismiss != null)
                TextButton(
                  onPressed: onDismiss,
                  style: _compactButton(fg),
                  child: const Text('关闭'),
                ),
            ],
          ),
        ] else if (saved) ...[
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('已保存', style: TextStyle(color: muted, fontSize: 12)),
              if (onReveal != null)
                TextButton(
                  onPressed: onReveal,
                  style: _compactButton(fg),
                  child: const Text('打开所在位置'),
                ),
            ],
          ),
        ] else if (localMissing) ...[
          const SizedBox(height: 6),
          Text(
            isSent
                ? kSourceFileMissing
                : (isDirect ? kDirectLocalMissing : kLocalFileMissing),
            style: TextStyle(color: muted, fontSize: 11),
          ),
        ] else if (onDownload != null) ...[
          const SizedBox(height: 6),
          Text(
            kOneTimeDownloadNotice,
            style: TextStyle(color: muted, fontSize: 11),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onDownload,
              style: _compactButton(fg),
              child: const Text('下载'),
            ),
          ),
        ],
      ],
    );
  }
}

/// 对方发来的大文件直传请求，画在输入栏上方。
class FileIncomingTile extends StatelessWidget {
  const FileIncomingTile({
    super.key,
    required this.name,
    required this.size,
    required this.done,
    required this.total,
    this.error,
    this.needsAccept = false,
    this.onAccept,
    this.onDecline,
    this.onCancel,
  });

  final String name;
  final int size;
  final int done;
  final int total;
  final String? error;
  final bool needsAccept;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final failed = error != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: failed ? AppTheme.red : AppTheme.lightGray),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    failed ? Icons.error_outline : Icons.download_outlined,
                    size: 16,
                    color: failed ? AppTheme.red : AppTheme.darkGray,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      failed
                          ? '接收失败：$name'
                          : '收到文件 $name（${formatFileSize(size)}）',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: failed ? AppTheme.red : AppTheme.black,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (needsAccept) ...[
                    TextButton(
                      onPressed: onDecline,
                      style: _compactButton(AppTheme.black),
                      child: const Text('拒绝'),
                    ),
                    TextButton(
                      onPressed: onAccept,
                      style: _compactButton(AppTheme.black),
                      child: const Text('接受'),
                    ),
                  ] else
                    TextButton(
                      onPressed: onCancel,
                      style: _compactButton(AppTheme.black),
                      child: Text(failed ? '关闭' : '取消'),
                    ),
                ],
              ),
              if (failed)
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 4),
                  child: Text(
                    fileTransferErrorText(error),
                    style: const TextStyle(color: AppTheme.red, fontSize: 12),
                  ),
                )
              else if (needsAccept)
                const Padding(
                  padding: EdgeInsets.only(right: 8, bottom: 4),
                  child: Text(
                    kDirectIncomingNotice,
                    style: TextStyle(color: AppTheme.darkGray, fontSize: 11),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
                  child: _ProgressLine(
                    done: done,
                    total: total,
                    color: AppTheme.black,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({
    required this.done,
    required this.total,
    required this.color,
    this.track,
  });

  final int done;
  final int total;
  final Color color;
  final Color? track;

  @override
  Widget build(BuildContext context) {
    final value = total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: value,
          minHeight: 3,
          color: color,
          backgroundColor: track ?? AppTheme.lightGray,
        ),
        const SizedBox(height: 4),
        Text(
          '${formatFileSize(done)} / ${formatFileSize(total)}',
          style: TextStyle(color: color, fontSize: 11),
        ),
      ],
    );
  }
}

ButtonStyle _compactButton(Color color) => TextButton.styleFrom(
  foregroundColor: color,
  visualDensity: VisualDensity.compact,
  padding: const EdgeInsets.symmetric(horizontal: 8),
  minimumSize: const Size(0, 32),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);
