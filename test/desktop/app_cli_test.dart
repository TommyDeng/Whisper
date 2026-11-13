import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/desktop/app_cli.dart';

void main() {
  group('命令行退出参数', () {
    test('只有带 --quit 才表示真正退出', () {
      expect(wantsQuit(const []), isFalse);
      expect(wantsQuit(const ['--show']), isFalse);
      expect(wantsQuit(const ['--quit']), isTrue);
      expect(wantsQuit(const ['--show', '--quit']), isTrue);
    });
  });

  group('桌面文件动作', () {
    test('有显示和退出两个动作，退出带 --quit', () {
      final file = File('packaging/linux/whisper.desktop');
      expect(file.existsSync(), isTrue);
      final text = file.readAsStringSync();
      expect(text, contains('Actions=Show;Quit;'));
      expect(text, contains('[Desktop Action Show]'));
      expect(text, contains('Name=显示'));
      expect(text, contains('[Desktop Action Quit]'));
      expect(text, contains('Name=退出'));
      expect(text, contains('Exec=whisper --quit'));
      expect(text, contains('Exec=whisper --show'));
    });

    test('安装包只装一个启动器，名字和窗口标识都等于 application-id', () {
      final cmake = File('linux/CMakeLists.txt').readAsStringSync();
      final appId = RegExp(r'set\(APPLICATION_ID "([^"]+)"\)')
          .firstMatch(cmake)!
          .group(1)!;
      final desktop = File('packaging/linux/whisper.desktop').readAsStringSync();
      expect(desktop, contains('StartupWMClass=$appId\n'));

      for (final script in const ['build-deb.sh', 'build-appimage.sh']) {
        final text = File('packaging/linux/$script').readAsStringSync();
        final installed = RegExp(r'/usr/share/applications/([^"\s]+\.desktop)"\s*$',
                multiLine: true)
            .allMatches(text)
            .map((m) => m.group(1))
            .toList();
        expect(installed, ['$appId.desktop'], reason: script);
      }
    });
  });
}
