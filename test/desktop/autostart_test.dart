import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/desktop/autostart.dart';

void main() {
  group('Linux 自启动目录', () {
    test('优先 XDG_CONFIG_HOME，否则 ~/.config', () {
      expect(
        linuxAutostartDirectory({'XDG_CONFIG_HOME': '/x', 'HOME': '/h'}),
        '/x/autostart',
      );
      expect(linuxAutostartDirectory({'HOME': '/h'}), '/h/.config/autostart');
      expect(
        linuxAutostartDirectory({'XDG_CONFIG_HOME': '', 'HOME': '/h'}),
        '/h/.config/autostart',
      );
      expect(linuxAutostartDirectory(const {}), isNull);
    });
  });

  group('桌面文件 Exec', () {
    test('路径加引号，保留字符转义', () {
      expect(
        quoteDesktopExecArg('/opt/whisper/whisper'),
        '"/opt/whisper/whisper"',
      );
      expect(quoteDesktopExecArg(r'/a b/$x"y\z`%'), r'"/a b/\$x\"y\\z\`%%"');
    });

    test('内容里有 Exec 和应用类型', () {
      final text = linuxAutostartEntry('/opt/whisper/whisper');
      expect(text, startsWith('[Desktop Entry]\n'));
      expect(text, contains('Type=Application\n'));
      expect(text, contains('Exec="/opt/whisper/whisper"\n'));
    });
  });

  group('LinuxAutostart', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('autostart_test'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('打开写文件，关闭删文件，重复操作不报错', () async {
      final directory = p.join(temp.path, 'nested', 'autostart');
      final autostart = LinuxAutostart(
        directory: directory,
        executable: '/opt/whisper/whisper',
      );
      final file = File(p.join(directory, 'whisper.desktop'));

      expect(await autostart.isEnabled(), isFalse);
      await autostart.setEnabled(false);
      expect(file.existsSync(), isFalse);

      await autostart.setEnabled(true);
      await autostart.setEnabled(true);
      expect(await autostart.isEnabled(), isTrue);
      expect(file.readAsStringSync(), contains('Exec="/opt/whisper/whisper"'));

      await autostart.setEnabled(false);
      expect(await autostart.isEnabled(), isFalse);
      expect(file.existsSync(), isFalse);
    });
  });

  group('WindowsAutostart', () {
    test('用 reg 读写当前用户的 Run 项', () async {
      final calls = <List<String>>[];
      var present = false;
      Future<ProcessResult> run(String exe, List<String> args) async {
        calls.add([exe, ...args]);
        switch (args.first) {
          case 'query':
            return ProcessResult(0, present ? 0 : 1, '', '');
          case 'add':
            present = true;
          case 'delete':
            present = false;
        }
        return ProcessResult(0, 0, '', '');
      }

      final autostart = WindowsAutostart(
        executable: r'C:\Program Files\Whisper\whisper.exe',
        run: run,
      );
      expect(await autostart.isEnabled(), isFalse);

      await autostart.setEnabled(true);
      expect(calls.last, [
        'reg', 'add', WindowsAutostart.runKey, '/v', 'Whisper', '/t', //
        'REG_SZ', '/d', r'"C:\Program Files\Whisper\whisper.exe"', '/f',
      ]);
      expect(await autostart.isEnabled(), isTrue);

      await autostart.setEnabled(false);
      expect(calls.last.sublist(0, 2), ['reg', 'delete']);
      expect(await autostart.isEnabled(), isFalse);

      // 本来就没有时不去删
      final before = calls.length;
      await autostart.setEnabled(false);
      expect(calls.sublist(before).map((c) => c[1]), ['query']);
    });

    test('reg 失败时抛异常', () async {
      final autostart = WindowsAutostart(
        executable: r'C:\whisper.exe',
        run: (_, _) async => ProcessResult(0, 1, '', ''),
      );
      expect(() => autostart.setEnabled(true), throwsStateError);
    });
  });
}
