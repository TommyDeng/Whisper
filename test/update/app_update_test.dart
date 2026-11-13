import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/update/app_update.dart';

/// 假的 Release：校验和文件和签名用 v1.0.5 的真实文件，安装包内容可以指定。
class _FakeHttp implements UpdateHttp {
  _FakeHttp({this.location, this.asset = const [], this.sums});

  String? location;
  List<int> asset;
  List<int>? sums;
  final requested = <String>[];

  @override
  Future<String?> redirectLocation(Uri uri) async {
    requested.add('$uri');
    return location;
  }

  @override
  Future<List<int>> getBytes(Uri uri) async {
    requested.add('$uri');
    if (uri.path.endsWith('.asc')) {
      return utf8.encode(
        File('test/update/fixtures/SHA256SUMS.asc').readAsStringSync(),
      );
    }
    return sums ?? File('test/update/fixtures/SHA256SUMS').readAsBytesSync();
  }

  @override
  Future<String> download(
    Uri uri,
    File target, {
    void Function(double progress)? onProgress,
  }) async {
    requested.add('$uri');
    await target.writeAsBytes(asset);
    onProgress?.call(1);
    return sha256.convert(asset).toString();
  }
}

void main() {
  group('compareVersions', () {
    test('按数字逐段比较，忽略 v 前缀和 build 号', () {
      expect(compareVersions('1.0.6', '1.0.5'), greaterThan(0));
      expect(compareVersions('1.0.10', '1.0.9'), greaterThan(0));
      expect(compareVersions('1.1.0', '1.0.9'), greaterThan(0));
      expect(compareVersions('2.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('1.0.5', '1.0.5+7'), 0);
      expect(compareVersions('v1.0.5', '1.0.5'), 0);
      expect(compareVersions('1.0.4', '1.0.5'), lessThan(0));
    });
  });

  group('versionFromReleaseUrl', () {
    test('只认正式版标签', () {
      const base = 'https://github.com/TommyDeng/Whisper/releases';
      expect(versionFromReleaseUrl('$base/tag/v1.0.6'), '1.0.6');
      expect(versionFromReleaseUrl('$base/tag/v1.0.6-rc.1'), isNull);
      expect(versionFromReleaseUrl(base), isNull);
      expect(versionFromReleaseUrl(null), isNull);
    });
  });

  group('detectInstallKind', () {
    InstallKind detect({
      bool windows = false,
      bool linux = false,
      String executable = '',
      Map<String, String> environment = const {},
      Set<String> files = const {},
    }) => detectInstallKind(
      isWindows: windows,
      isLinux: linux,
      executable: executable,
      environment: environment,
      fileExists: files.contains,
    );

    test('Windows：旁边有卸载程序才算安装器装的', () {
      const exe = r'C:\Users\me\AppData\Local\Whisper\whisper.exe';
      expect(
        detect(
          windows: true,
          executable: exe,
          files: {r'C:\Users\me\AppData\Local\Whisper\unins000.exe'},
        ),
        InstallKind.windowsInstaller,
      );
      expect(detect(windows: true, executable: exe), InstallKind.manual);
    });

    test('Linux：AppImage、deb、其它', () {
      expect(
        detect(
          linux: true,
          executable: '/tmp/.mount_x/whisper',
          environment: {'APPIMAGE': '/home/me/whisper.AppImage'},
        ),
        InstallKind.linuxAppImage,
      );
      expect(
        detect(
          linux: true,
          executable: '/opt/whisper/whisper',
          files: {'/usr/bin/pkexec'},
        ),
        InstallKind.linuxDeb,
      );
      // 没有 pkexec 就没法提权安装
      expect(
        detect(linux: true, executable: '/opt/whisper/whisper'),
        InstallKind.manual,
      );
      expect(
        detect(linux: true, executable: '/home/me/bundle/whisper'),
        InstallKind.manual,
      );
    });
  });

  test('安装包文件名和发布产物一致', () {
    final sums = parseSha256Sums(
      File('test/update/fixtures/SHA256SUMS').readAsStringSync(),
    );
    for (final kind in InstallKind.values) {
      final name = updateAssetName(kind, '1.0.5');
      if (kind == InstallKind.manual) {
        expect(name, isNull);
      } else {
        expect(sums, contains(name));
      }
    }
    expect(
      sums['whisper_1.0.5_amd64.deb'],
      'c7c79c1b222010802d598cb4df0f32640ef6431879efb1d487fdb4c06ec854ee',
    );
  });

  test('Windows 更新脚本：先装再启动，路径加引号', () {
    final script = windowsUpdateScript(
      r'C:\Temp\100%\Whisper-Setup-1.0.6-x64.exe',
      r'C:\Program Files\Whisper\whisper.exe',
    );
    final lines = const LineSplitter().convert(script);
    final install = lines.indexWhere((line) => line.contains('/SILENT'));
    final launch = lines.indexWhere((line) => line.startsWith('start ""'));
    expect(install, greaterThan(0));
    expect(launch, greaterThan(install));
    expect(lines[install], startsWith(r'"C:\Temp\100%%\Whisper-Setup'));
    expect(lines[launch], r'start "" "C:\Program Files\Whisper\whisper.exe"');
  });

  group('GithubAppUpdater', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('update_test'));
    tearDown(() => temp.deleteSync(recursive: true));

    GithubAppUpdater updater(
      _FakeHttp http, {
      InstallKind kind = InstallKind.linuxDeb,
      String? appImagePath,
      ProcessRun? run,
      ProcessSpawn? spawn,
    }) => GithubAppUpdater(
      kind: kind,
      executable: '/opt/whisper/whisper',
      appImagePath: appImagePath,
      http: http,
      run: run ?? (_, _) async => ProcessResult(0, 0, '', ''),
      spawn: spawn ?? (_, _) async {},
      ownPid: 4242,
      tempRoot: temp,
    );

    test('latestVersion 从跳转地址取版本，网络出错返回 null', () async {
      final http = _FakeHttp(
        location: 'https://github.com/TommyDeng/Whisper/releases/tag/v1.0.6',
      );
      expect(await updater(http).latestVersion(), '1.0.6');
      expect(http.requested.single, '$kReleasesUrl/latest');
      http.location = null;
      expect(await updater(http).latestVersion(), isNull);
    });

    test('签名不对就不下载安装包', () async {
      final http = _FakeHttp(
        sums: utf8.encode('${'0' * 64}  whisper_1.0.5_amd64.deb\n'),
      );
      await expectLater(
        updater(http).downloadVerified('1.0.5'),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('签名'),
          ),
        ),
      );
      expect(http.requested.where((url) => url.endsWith('.deb')), isEmpty);
    });

    test('安装包哈希不对就删掉并报错', () async {
      final http = _FakeHttp(asset: utf8.encode('被换过的安装包'));
      await expectLater(
        updater(http).downloadVerified('1.0.5'),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('安装包校验'),
          ),
        ),
      );
      expect(temp.listSync(), isEmpty);
    });

    test('deb：用 pkexec 安装，装完等本进程退出后重新启动', () async {
      final ran = <List<String>>[];
      final spawned = <List<String>>[];
      final file = File('${temp.path}/whisper_1.0.6_amd64.deb')
        ..writeAsStringSync('x');
      await updater(
        _FakeHttp(),
        run: (exe, args) async {
          ran.add([exe, ...args]);
          return ProcessResult(0, 0, '', '');
        },
        spawn: (exe, args) async => spawned.add([exe, ...args]),
      ).install(file);
      expect(ran.single, ['pkexec', 'apt-get', 'install', '-y', file.path]);
      expect(spawned.single.first, '/bin/sh');
      expect(spawned.single.sublist(3), ['/opt/whisper/whisper', '4242']);
    });

    test('deb：用户取消授权或安装失败时不重启', () async {
      for (final (code, text) in [(126, '授权'), (1, '没有成功')]) {
        var spawned = false;
        await expectLater(
          updater(
            _FakeHttp(),
            run: (_, _) async => ProcessResult(0, code, '', ''),
            spawn: (_, _) async => spawned = true,
          ).install(File('${temp.path}/x.deb')),
          throwsA(
            isA<UpdateException>().having(
              (e) => e.message,
              'message',
              contains(text),
            ),
          ),
        );
        expect(spawned, isFalse);
      }
    });

    test('AppImage：替换原文件并重新启动它', () async {
      final target = File('${temp.path}/whisper.AppImage')
        ..writeAsStringSync('old');
      final file = File('${temp.path}/download.AppImage')
        ..writeAsStringSync('new');
      final spawned = <List<String>>[];
      await updater(
        _FakeHttp(),
        kind: InstallKind.linuxAppImage,
        appImagePath: target.path,
        run: Process.run,
        spawn: (exe, args) async => spawned.add([exe, ...args]),
      ).install(file);
      expect(target.readAsStringSync(), 'new');
      expect(target.statSync().modeString(), contains('x'));
      expect(File('${target.path}.new').existsSync(), isFalse);
      expect(spawned.single.sublist(3), [target.path, '4242']);
    });

    test('Windows：写出批处理并脱离本进程运行', () async {
      final file = File('${temp.path}/Whisper-Setup-1.0.6-x64.exe')
        ..writeAsStringSync('x');
      final spawned = <List<String>>[];
      await updater(
        _FakeHttp(),
        kind: InstallKind.windowsInstaller,
        spawn: (exe, args) async => spawned.add([exe, ...args]),
      ).install(file);
      expect(spawned.single.sublist(0, 2), ['cmd', '/c']);
      expect(
        File(spawned.single[2]).readAsStringSync(),
        contains('Whisper-Setup-1.0.6-x64.exe" /SILENT'),
      );
    });

    test('便携包不能自动更新', () async {
      await expectLater(
        updater(
          _FakeHttp(),
          kind: InstallKind.manual,
        ).downloadVerified('1.0.6'),
        throwsA(isA<UpdateException>()),
      );
    });
  });
}
