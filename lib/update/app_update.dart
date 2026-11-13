/// 检查新版本并更新客户端。
///
/// 新版本从 GitHub Releases 取。下载的安装包必须先过两关才会运行：
/// `SHA256SUMS` 的签名用内置的发布公钥校验，安装包的 SHA-256 与其中一致。
/// 只在用户打开「关于」时才联网检查。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'pgp_verify.dart';

const kReleasesUrl = 'https://github.com/TommyDeng/Whisper/releases';

/// 给用户看的失败原因。
class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 比较两个版本号（`1.0.5`、`1.0.5+7`、`v1.0.5` 都行，build 号不参与比较）。
/// [a] 更新返回正数，一样返回 0。
int compareVersions(String a, String b) {
  List<int> parts(String text) {
    var core = text.trim();
    if (core.startsWith('v')) core = core.substring(1);
    core = core.split('+').first.split('-').first;
    return [for (final part in core.split('.')) int.tryParse(part) ?? 0];
  }

  final left = parts(a);
  final right = parts(b);
  for (var i = 0; i < left.length || i < right.length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// 从 `…/releases/latest` 跳转到的地址（`…/releases/tag/v1.0.6`）里取版本号。
/// 只认 `v数字.数字.数字` 这种正式版标签。
String? versionFromReleaseUrl(String? location) {
  if (location == null) return null;
  final match = RegExp(r'/releases/tag/v(\d+\.\d+\.\d+)$').firstMatch(location);
  return match?.group(1);
}

/// 这份客户端是怎么装的，决定能不能自动更新、用哪个安装包。
enum InstallKind {
  /// Windows 安装器装的（程序旁边有卸载程序）。
  windowsInstaller,

  /// deb 包装的，在 `/opt/whisper`。更新时系统会问一次管理员密码。
  linuxDeb,

  /// AppImage，直接替换文件本身。
  linuxAppImage,

  /// 便携包或开发构建：只能带用户去下载页。
  manual,
}

InstallKind detectInstallKind({
  required bool isWindows,
  required bool isLinux,
  required String executable,
  required Map<String, String> environment,
  required bool Function(String path) fileExists,
}) {
  if (isWindows) {
    final uninstaller = p.windows.join(
      p.windows.dirname(executable),
      'unins000.exe',
    );
    return fileExists(uninstaller)
        ? InstallKind.windowsInstaller
        : InstallKind.manual;
  }
  if (isLinux) {
    final appImage = environment['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty) {
      return InstallKind.linuxAppImage;
    }
    if (executable == '/opt/whisper/whisper' && fileExists('/usr/bin/pkexec')) {
      return InstallKind.linuxDeb;
    }
  }
  return InstallKind.manual;
}

/// [version] 这一版里对应的安装包文件名；[InstallKind.manual] 没有。
String? updateAssetName(InstallKind kind, String version) => switch (kind) {
  InstallKind.windowsInstaller => 'Whisper-Setup-$version-x64.exe',
  InstallKind.linuxDeb => 'whisper_${version}_amd64.deb',
  InstallKind.linuxAppImage => 'whisper-$version-x86_64.AppImage',
  InstallKind.manual => null,
};

/// 解析 `SHA256SUMS`：文件名 → 小写十六进制哈希。
Map<String, String> parseSha256Sums(String text) {
  final sums = <String, String>{};
  for (final line in const LineSplitter().convert(text)) {
    final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line);
    if (match != null) {
      sums[match.group(2)!.trim()] = match.group(1)!.toLowerCase();
    }
  }
  return sums;
}

/// 更新要用到的网络访问，测试里换成假的。
abstract class UpdateHttp {
  /// 请求 [uri] 但不跟随跳转，返回 `Location`。
  Future<String?> redirectLocation(Uri uri);

  Future<List<int>> getBytes(Uri uri);

  /// 把 [uri] 存到 [target]，返回内容的 SHA-256（小写十六进制）。
  Future<String> download(
    Uri uri,
    File target, {
    void Function(double progress)? onProgress,
  });
}

class IoUpdateHttp implements UpdateHttp {
  HttpClient _client() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 15);

  @override
  Future<String?> redirectLocation(Uri uri) async {
    final client = _client();
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();
      await response.drain<void>();
      return response.headers.value(HttpHeaders.locationHeader);
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw UpdateException('下载失败（${response.statusCode}）');
    }
    return response;
  }

  @override
  Future<List<int>> getBytes(Uri uri) async {
    final client = _client();
    try {
      final response = await _get(client, uri);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        // 校验和文件只有几百字节，过大说明拿到的不是它。
        if (builder.length > 1 << 20) {
          throw const UpdateException('校验文件异常');
        }
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<String> download(
    Uri uri,
    File target, {
    void Function(double progress)? onProgress,
  }) async {
    final client = _client();
    final sink = target.openWrite();
    try {
      final response = await _get(client, uri);
      final total = response.contentLength;
      var received = 0;
      final digests = _DigestSink();
      final hasher = sha256.startChunkedConversion(digests);
      await for (final chunk in response) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      hasher.close();
      await sink.flush();
      return digests.value.toString();
    } finally {
      await sink.close();
      client.close(force: true);
    }
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 「关于」里用的更新入口。
abstract class AppUpdater {
  InstallKind get kind;

  /// 最新正式版的版本号；查不到返回 null。
  Future<String?> latestVersion();

  /// 下载 [version] 的安装包、校验、安装。正常返回后调用方应退出应用，
  /// 新版本会自己启动。失败抛 [UpdateException]。
  Future<void> downloadAndInstall(
    String version, {
    void Function(double progress)? onProgress,
    void Function()? onInstalling,
  });
}

typedef ProcessRun = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);
typedef ProcessSpawn = Future<void> Function(
  String executable,
  List<String> arguments,
);

class GithubAppUpdater implements AppUpdater {
  GithubAppUpdater({
    required this.kind,
    required this.executable,
    this.appImagePath,
    UpdateHttp? http,
    List<int>? publicKey,
    ProcessRun? run,
    ProcessSpawn? spawn,
    this.isWindows = false,
    this.ownPid = 0,
    Directory? tempRoot,
  }) : _http = http ?? IoUpdateHttp(),
       _publicKey = publicKey ?? kReleasePublicKey,
       _run = run ?? Process.run,
       _spawn = spawn ?? _spawnDetached,
       _tempRoot = tempRoot ?? Directory.systemTemp;

  /// 按当前进程的实际情况创建。
  factory GithubAppUpdater.forPlatform() {
    final environment = Platform.environment;
    return GithubAppUpdater(
      kind: detectInstallKind(
        isWindows: Platform.isWindows,
        isLinux: Platform.isLinux,
        executable: Platform.resolvedExecutable,
        environment: environment,
        fileExists: (path) => File(path).existsSync(),
      ),
      executable: Platform.resolvedExecutable,
      appImagePath: environment['APPIMAGE'],
      isWindows: Platform.isWindows,
      ownPid: pid,
    );
  }

  @override
  final InstallKind kind;

  /// 当前运行的程序，更新后重新启动它。
  final String executable;

  /// AppImage 文件本身的位置（`$APPIMAGE`）。
  final String? appImagePath;

  final bool isWindows;

  /// 本进程号；Linux 上新进程要等它退出再启动，否则会被单实例逻辑并回旧进程。
  final int ownPid;

  final UpdateHttp _http;
  final List<int> _publicKey;
  final ProcessRun _run;
  final ProcessSpawn _spawn;
  final Directory _tempRoot;

  static Future<void> _spawnDetached(
    String executable,
    List<String> arguments,
  ) async {
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  }

  @override
  Future<String?> latestVersion() async {
    try {
      return versionFromReleaseUrl(
        await _http.redirectLocation(Uri.parse('$kReleasesUrl/latest')),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> downloadAndInstall(
    String version, {
    void Function(double progress)? onProgress,
    void Function()? onInstalling,
  }) async {
    final file = await downloadVerified(version, onProgress: onProgress);
    onInstalling?.call();
    await install(file);
  }

  /// 下载并校验，返回本地文件。校验不过会删掉文件并抛异常。
  Future<File> downloadVerified(
    String version, {
    void Function(double progress)? onProgress,
  }) async {
    final name = updateAssetName(kind, version);
    if (name == null) throw const UpdateException('这种安装方式不能自动更新');
    final base = '$kReleasesUrl/download/v$version';

    final List<int> sums;
    final String signature;
    try {
      sums = await _http.getBytes(Uri.parse('$base/SHA256SUMS'));
      signature = utf8.decode(
        await _http.getBytes(Uri.parse('$base/SHA256SUMS.asc')),
      );
    } on UpdateException {
      rethrow;
    } catch (_) {
      throw const UpdateException('下载失败，请检查网络');
    }
    final signed = await verifyDetachedSignature(
      armoredSignature: signature,
      data: sums,
      publicKey: _publicKey,
    );
    if (!signed) throw const UpdateException('签名校验没有通过，已停止更新');
    final expected = parseSha256Sums(utf8.decode(sums))[name];
    if (expected == null) throw const UpdateException('这一版没有对应的安装包');

    final directory = await _tempRoot.createTemp('whisper-update-');
    final file = File(p.join(directory.path, name));
    final String actual;
    try {
      actual = await _http.download(
        Uri.parse('$base/$name'),
        file,
        onProgress: onProgress,
      );
    } on UpdateException {
      await _discard(directory);
      rethrow;
    } catch (_) {
      await _discard(directory);
      throw const UpdateException('下载失败，请检查网络');
    }
    if (actual.toLowerCase() != expected) {
      await _discard(directory);
      throw const UpdateException('安装包校验没有通过，已停止更新');
    }
    return file;
  }

  Future<void> _discard(Directory directory) async {
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  }

  /// 安装已校验过的 [file]，并安排新版本在本进程退出后启动。
  Future<void> install(File file) async {
    switch (kind) {
      case InstallKind.windowsInstaller:
        await _installWindows(file);
      case InstallKind.linuxDeb:
        await _installDeb(file);
      case InstallKind.linuxAppImage:
        await _installAppImage(file);
      case InstallKind.manual:
        throw const UpdateException('这种安装方式不能自动更新');
    }
  }

  Future<void> _installWindows(File file) async {
    // 交给一个脱离本进程的批处理：等本进程退出，静默跑安装器，再启动新版本。
    final script = File(p.join(file.parent.path, 'update.bat'));
    await script.writeAsString(windowsUpdateScript(file.path, executable));
    await _spawn('cmd', ['/c', script.path]);
  }

  Future<void> _installDeb(File file) async {
    // pkexec 会弹出系统的密码框；apt 顺带处理依赖变化。
    final result = await _run('pkexec', [
      'apt-get', 'install', '-y', file.path, //
    ]);
    if (result.exitCode == 126 || result.exitCode == 127) {
      throw const UpdateException('没有授权，已取消更新');
    }
    if (result.exitCode != 0) {
      throw const UpdateException('安装没有成功');
    }
    await _relaunchAfterExit(executable);
  }

  Future<void> _installAppImage(File file) async {
    final target = appImagePath;
    if (target == null || target.isEmpty) {
      throw const UpdateException('找不到 AppImage 文件的位置');
    }
    try {
      // 先放到同一目录再改名，改名是原子的，不会留下半个文件。
      final staged = await file.copy('$target.new');
      final chmod = await _run('chmod', ['+x', staged.path]);
      if (chmod.exitCode != 0) throw const UpdateException('安装没有成功');
      await staged.rename(target);
    } on UpdateException {
      rethrow;
    } catch (_) {
      throw const UpdateException('没能替换 AppImage 文件，请检查它所在目录的权限');
    }
    await _relaunchAfterExit(target);
  }

  Future<void> _relaunchAfterExit(String program) => _spawn('/bin/sh', [
    '-c',
    r'while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec "$0"',
    program,
    '$ownPid',
  ]);
}

/// Windows 更新用的批处理内容。
String windowsUpdateScript(String installer, String executable) {
  // 批处理里 % 要写成 %%。
  String quote(String path) => '"${path.replaceAll('%', '%%')}"';
  return '@echo off\r\n'
      'chcp 65001 >nul\r\n'
      // 没有控制台时 timeout 不能用，拿 ping 等两秒让旧进程退出。
      'ping -n 3 127.0.0.1 >nul\r\n'
      '${quote(installer)} /SILENT /SUPPRESSMSGBOXES /NORESTART '
      '/CLOSEAPPLICATIONS\r\n'
      'start "" ${quote(executable)}\r\n';
}
