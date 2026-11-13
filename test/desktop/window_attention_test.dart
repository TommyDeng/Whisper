import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/desktop/window_attention.dart';

void main() {
  trayBlinkTests();
  group('任务栏闪烁', () {
    test('窗口在前台且可见时不闪', () {
      expect(
        shouldFlashTaskbar(windowFocused: true, windowHidden: false),
        isFalse,
      );
    });

    test('藏到托盘或失去焦点时要闪', () {
      expect(
        shouldFlashTaskbar(windowFocused: true, windowHidden: true),
        isTrue,
      );
      expect(
        shouldFlashTaskbar(windowFocused: false, windowHidden: false),
        isTrue,
      );
      expect(
        shouldFlashTaskbar(windowFocused: false, windowHidden: true),
        isTrue,
      );
    });
  });
}

class _Icons {
  final shown = <String>[];
  Future<void> set(String icon) async => shown.add(icon);
}

void trayBlinkTests() {
  group('托盘图标闪烁', () {
    test('开始后在提醒图标和普通图标之间交替', () {
      fakeAsync((async) {
        final icons = _Icons();
        final blinker = TrayBlinker(
          setIcon: icons.set,
          normalIcon: 'normal',
          alertIcon: 'alert',
        );
        blinker.start();
        expect(icons.shown, ['alert']);
        async.elapse(TrayBlinker.interval * 3);
        expect(icons.shown, ['alert', 'normal', 'alert', 'normal']);
        expect(blinker.active, isTrue);
        blinker.stop();
      });
    });

    test('重复开始不会叠加定时器', () {
      fakeAsync((async) {
        final icons = _Icons();
        final blinker = TrayBlinker(
          setIcon: icons.set,
          normalIcon: 'normal',
          alertIcon: 'alert',
        );
        blinker.start();
        blinker.start();
        async.elapse(TrayBlinker.interval);
        expect(icons.shown, ['alert', 'normal']);
        blinker.stop();
      });
    });

    test('停止后恢复普通图标且不再变化', () {
      fakeAsync((async) {
        final icons = _Icons();
        final blinker = TrayBlinker(
          setIcon: icons.set,
          normalIcon: 'normal',
          alertIcon: 'alert',
        );
        blinker.start();
        blinker.stop();
        expect(icons.shown, ['alert', 'normal']);
        expect(blinker.active, isFalse);
        async.elapse(TrayBlinker.interval * 5);
        expect(icons.shown, ['alert', 'normal']);
      });
    });

    test('没在闪时停止不碰图标', () {
      final icons = _Icons();
      TrayBlinker(
        setIcon: icons.set,
        normalIcon: 'normal',
        alertIcon: 'alert',
      ).stop();
      expect(icons.shown, isEmpty);
    });

    test('换图标失败不影响后续闪烁', () {
      fakeAsync((async) {
        var calls = 0;
        final blinker = TrayBlinker(
          setIcon: (_) async {
            calls++;
            throw StateError('no tray');
          },
          normalIcon: 'normal',
          alertIcon: 'alert',
        );
        blinker.start();
        async.elapse(TrayBlinker.interval * 2);
        expect(calls, 3);
        blinker.stop();
        async.flushMicrotasks();
      });
    });
  });
}
