import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_webrtc_spike/session/progress_timeout.dart';

void main() {
  test('stall timer resets when another frame arrives', () async {
    var stalls = 0;
    final timeout = ProgressTimeout(stall: const Duration(milliseconds: 80), onStall: () => stalls++);
    timeout.start();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    timeout.bump();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(stalls, 0);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(stalls, 1);
    timeout.cancel();
  });
}
