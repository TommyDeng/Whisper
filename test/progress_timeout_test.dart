import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/session/progress_timeout.dart';

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

  test('a peer that joins 60s later does not trip the stall clock', () {
    fakeAsync((async) {
      var stalls = 0;
      var waits = 0;
      final watch = AutorunWatch(
        waitForPeer: const Duration(seconds: 600),
        stall: const Duration(seconds: 30),
        onWaitTimeout: () => waits++,
        onStall: () => stalls++,
      );
      watch.start();
      async.elapse(const Duration(seconds: 60));
      expect(stalls, 0);
      expect(waits, 0);
      expect(watch.transferStarted, isFalse);
      watch.beginTransfer();
      async.elapse(const Duration(seconds: 20));
      watch.onFrame();
      async.elapse(const Duration(seconds: 20));
      expect(stalls, 0);
      async.elapse(const Duration(seconds: 30));
      expect(stalls, 1);
      expect(waits, 0);
      watch.cancel();
    });
  });
}
