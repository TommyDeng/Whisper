/// 「关于」对话框：版本号和客户端下载地址。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../desktop/autostart.dart';
import '../update/app_update.dart';
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

/// 弹出关于对话框。[autostart] 为 null 时不显示开机启动开关；
/// [updater] 为 null 时不检查新版本。更新装好后调用 [onQuitForUpdate] 退出应用。
Future<void> showAboutWhisperDialog(
  BuildContext context, {
  Autostart? autostart,
  AppUpdater? updater,
  Future<void> Function()? onQuitForUpdate,
}) async {
  var versionText = '正在读取版本…';
  String? currentVersion;
  try {
    final info = await PackageInfo.fromPlatform();
    versionText = formatAppVersion(info.version, info.buildNumber);
    currentVersion = info.version;
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
          if (updater != null && currentVersion != null)
            UpdateSection(
              updater: updater,
              currentVersion: currentVersion,
              onQuit: onQuitForUpdate ?? () async {},
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
          if (autostart != null) AutostartSwitch(autostart: autostart),
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

/// 版本号下面的更新区：打开时查一次最新版本，有新版本就给出「更新客户端」。
class UpdateSection extends StatefulWidget {
  const UpdateSection({
    super.key,
    required this.updater,
    required this.currentVersion,
    required this.onQuit,
  });

  final AppUpdater updater;
  final String currentVersion;

  /// 新版本装好后退出当前应用，新版本会自己启动。
  final Future<void> Function() onQuit;

  @override
  State<UpdateSection> createState() => _UpdateSectionState();
}

enum _UpdatePhase { checking, unknown, upToDate, available, working, done }

class _UpdateSectionState extends State<UpdateSection> {
  var _phase = _UpdatePhase.checking;
  String? _latest;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    final latest = await widget.updater.latestVersion();
    if (!mounted) return;
    setState(() {
      _latest = latest;
      if (latest == null) {
        _phase = _UpdatePhase.unknown;
      } else if (compareVersions(latest, widget.currentVersion) > 0) {
        _phase = _UpdatePhase.available;
      } else {
        _phase = _UpdatePhase.upToDate;
      }
    });
  }

  bool get _manual => widget.updater.kind == InstallKind.manual;

  Future<void> _update() async {
    final latest = _latest;
    if (latest == null) return;
    if (_manual) {
      unawaitedLaunch(Uri.parse('$kReleasesUrl/tag/v$latest'));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('更新到 $latest？'),
        content: Text(
          widget.updater.kind == InstallKind.linuxDeb
              ? '会下载并安装新版本，安装时系统会问一次管理员密码。装好后耳语会自动重启，正在进行的通话会断开。'
              : '会下载并安装新版本。装好后耳语会自动重启，正在进行的通话会断开。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('更新'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _phase = _UpdatePhase.working;
      _status = '正在下载…';
      _error = null;
    });
    try {
      await widget.updater.downloadAndInstall(
        latest,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _status = '正在下载… ${(progress * 100).floor()}%');
        },
        onInstalling: () {
          if (mounted) setState(() => _status = '正在安装…');
        },
      );
    } on UpdateException catch (error) {
      if (mounted) {
        setState(() {
          _phase = _UpdatePhase.available;
          _error = error.message;
        });
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() {
          _phase = _UpdatePhase.available;
          _error = '更新没有成功';
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _phase = _UpdatePhase.done;
        _status = '正在重启…';
      });
    }
    await widget.onQuit();
  }

  @override
  Widget build(BuildContext context) {
    const hint = TextStyle(color: AppTheme.darkGray, fontSize: 12);
    final Widget child;
    switch (_phase) {
      case _UpdatePhase.checking:
        child = const Text('正在检查更新…', style: hint);
      case _UpdatePhase.unknown:
        child = const Text('没能检查更新', style: hint);
      case _UpdatePhase.upToDate:
        child = const Text('已是最新版本', style: hint);
      case _UpdatePhase.working:
      case _UpdatePhase.done:
        child = Text(_status ?? '', style: hint);
      case _UpdatePhase.available:
        child = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '有新版本 $_latest',
                    style: const TextStyle(color: AppTheme.black, fontSize: 13),
                  ),
                ),
                FilledButton(
                  onPressed: () => unawaited(_update()),
                  child: Text(_manual ? '前往下载' : '更新客户端'),
                ),
              ],
            ),
            if (_manual) const Text('这份客户端不是用安装包装的，需要手动下载新版本。', style: hint),
            if (_error != null) Text(_error!, style: hint),
          ],
        );
    }
    return Padding(padding: const EdgeInsets.only(top: 4), child: child);
  }
}

/// 「开机自动启动」开关。状态直接读系统里的启动项，改动立即生效。
class AutostartSwitch extends StatefulWidget {
  const AutostartSwitch({super.key, required this.autostart});

  final Autostart autostart;

  @override
  State<AutostartSwitch> createState() => _AutostartSwitchState();
}

class _AutostartSwitchState extends State<AutostartSwitch> {
  /// 还没读到系统状态时为 null，开关先不可点。
  bool? _enabled;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    bool enabled;
    try {
      enabled = await widget.autostart.isEnabled();
    } catch (_) {
      enabled = false;
    }
    if (mounted) setState(() => _enabled = enabled);
  }

  Future<void> _set(bool value) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await widget.autostart.setEnabled(value);
    } catch (_) {
      error = '设置没有成功';
    }
    bool enabled;
    try {
      enabled = await widget.autostart.isEnabled();
    } catch (_) {
      enabled = _enabled ?? false;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _enabled = enabled;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '开机自动启动',
                  style: TextStyle(color: AppTheme.black, fontSize: 14),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: AppTheme.darkGray,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          Switch(
            value: enabled ?? false,
            onChanged: enabled == null || _busy
                ? null
                : (value) => unawaited(_set(value)),
          ),
        ],
      ),
    );
  }
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
