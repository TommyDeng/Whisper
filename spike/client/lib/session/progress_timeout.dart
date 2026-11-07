import 'dart:async';

import 'autorun_config.dart';

/// Fires [onStall] only after [stall] with no [bump]. Used so a slow but
/// moving file receive is not reported as an autorun timeout.
class ProgressTimeout {
  ProgressTimeout({required this.stall, required this.onStall});

  final Duration stall;
  final void Function() onStall;
  Timer? _timer;

  void start() => bump();

  void bump() {
    _timer?.cancel();
    _timer = Timer(stall, onStall);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Waits for a peer without a stall clock. The stall clock starts only when
/// [beginTransfer] runs, and [onFrame] resets it.
class AutorunWatch {
  AutorunWatch({
    required this.onWaitTimeout,
    required this.onStall,
    this.waitForPeer = defaultWaitForPeer,
    this.stall = autorunStall,
  });

  final Duration waitForPeer;
  final Duration stall;
  final void Function() onWaitTimeout;
  final void Function() onStall;
  Timer? _wait;
  ProgressTimeout? _stallTimer;
  bool transferStarted = false;

  void start() {
    _wait?.cancel();
    _wait = Timer(waitForPeer, () {
      if (!transferStarted) onWaitTimeout();
    });
  }

  void beginTransfer() {
    if (transferStarted) {
      _stallTimer?.bump();
      return;
    }
    transferStarted = true;
    _wait?.cancel();
    _wait = null;
    _stallTimer = ProgressTimeout(stall: stall, onStall: onStall)..start();
  }

  void onFrame() => beginTransfer();

  void cancel() {
    _wait?.cancel();
    _wait = null;
    _stallTimer?.cancel();
    _stallTimer = null;
  }
}
