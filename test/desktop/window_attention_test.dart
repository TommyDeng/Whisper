import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/desktop/window_attention.dart';

void main() {
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
