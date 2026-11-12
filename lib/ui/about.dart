/// 「关于」对话框：版本号和客户端下载地址。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_theme.dart';

/// 发布页，给用户下载客户端。
const kClientDownloadUrl = 'https://github.com/TommyDeng/Whisper/releases';

/// 把 [version] 和 [build] 排成一行，例如 `1.0.3（4）`。
String formatAppVersion(String version, String build) {
  final v = version.trim();
  final b = build.trim();
  if (v.isEmpty && b.isEmpty) return '未知版本';
  if (b.isEmpty) return v;
  if (v.isEmpty) return b;
  return '$v（$b）';
}

/// 弹出关于对话框。
Future<void> showAboutWhisperDialog(BuildContext context) async {
  var versionText = '正在读取版本…';
  try {
    final info = await PackageInfo.fromPlatform();
    versionText = formatAppVersion(info.version, info.buildNumber);
  } catch (_) {
    versionText = '无法读取版本';
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('关于耳语'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '版本 $versionText',
            style: const TextStyle(color: AppTheme.black, fontSize: 14),
          ),
          const SizedBox(height: 12),
          const Text(
            '客户端下载',
            style: TextStyle(color: AppTheme.darkGray, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => unawaitedLaunch(Uri.parse(kClientDownloadUrl)),
                  child: const Text(
                    kClientDownloadUrl,
                    style: TextStyle(
                      color: AppTheme.black,
                      fontSize: 13,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '复制链接',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () async {
                  await Clipboard.setData(
                    const ClipboardData(text: kClientDownloadUrl),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('已复制下载地址')));
                  }
                },
              ),
            ],
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// 打开失败时静默忽略，避免关于框被异常打断。
void unawaitedLaunch(Uri uri) {
  unawaited(
    launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    ).then((_) {}, onError: (_) {}),
  );
}
