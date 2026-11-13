/// 开机自动启动：Linux 写 `~/.config/autostart/` 下的桌面文件，
/// Windows 写当前用户的 `Run` 注册表项。开关状态以系统里实际有没有这一项为准。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

abstract class Autostart {
  /// 当前平台的实现；不支持的平台返回 null。
  static Autostart? forPlatform() {
    if (Platform.isLinux) {
      final directory = linuxAutostartDirectory(Platform.environment);
      if (directory == null) return null;
      return LinuxAutostart(
        directory: directory,
        // AppImage 每次运行挂载路径都不同，要写 AppImage 文件本身的路径。
        executable:
            Platform.environment['APPIMAGE'] ?? Platform.resolvedExecutable,
      );
    }
    if (Platform.isWindows) {
      return WindowsAutostart(executable: Platform.resolvedExecutable);
    }
    return null;
  }

  Future<bool> isEnabled();

  /// 打开或关闭；失败时抛异常。
  Future<void> setEnabled(bool enabled);
}

/// 按 XDG 规范找自启动目录；连 HOME 都没有时返回 null。
String? linuxAutostartDirectory(Map<String, String> environment) {
  final configHome = environment['XDG_CONFIG_HOME'];
  if (configHome != null && configHome.isNotEmpty) {
    return p.join(configHome, 'autostart');
  }
  final home = environment['HOME'];
  if (home == null || home.isEmpty) return null;
  return p.join(home, '.config', 'autostart');
}

/// 桌面文件 `Exec=` 里的一个参数：加双引号并转义保留字符。
String quoteDesktopExecArg(String arg) {
  final escaped = arg
      .replaceAllMapped(RegExp(r'[\\"`$]'), (match) => '\\${match[0]}')
      .replaceAll('%', '%%');
  return '"$escaped"';
}

/// 自启动桌面文件的内容。
String linuxAutostartEntry(String executable) {
  return '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=耳语 Whisper\n'
      'Exec=${quoteDesktopExecArg(executable)}\n'
      'Icon=whisper\n'
      'Terminal=false\n'
      'X-GNOME-Autostart-enabled=true\n';
}

class LinuxAutostart implements Autostart {
  LinuxAutostart({required this.directory, required this.executable});

  final String directory;
  final String executable;

  File get _file => File(p.join(directory, 'whisper.desktop'));

  @override
  Future<bool> isEnabled() => _file.exists();

  @override
  Future<void> setEnabled(bool enabled) async {
    final file = _file;
    if (enabled) {
      await file.parent.create(recursive: true);
      await file.writeAsString(linuxAutostartEntry(executable), flush: true);
    } else if (await file.exists()) {
      await file.delete();
    }
  }
}

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class WindowsAutostart implements Autostart {
  WindowsAutostart({required this.executable, ProcessRunner? run})
    : _run = run ?? Process.run;

  static const runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const valueName = 'Whisper';

  final String executable;
  final ProcessRunner _run;

  @override
  Future<bool> isEnabled() async {
    final result = await _run('reg', ['query', runKey, '/v', valueName]);
    return result.exitCode == 0;
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    if (enabled) {
      final result = await _run('reg', [
        'add', runKey, '/v', valueName, '/t', 'REG_SZ', //
        '/d', '"$executable"', '/f',
      ]);
      if (result.exitCode != 0) {
        throw StateError('写入开机启动项失败');
      }
      return;
    }
    if (!await isEnabled()) return;
    final result = await _run('reg', [
      'delete', runKey, '/v', valueName, '/f', //
    ]);
    if (result.exitCode != 0) {
      throw StateError('删除开机启动项失败');
    }
  }
}
