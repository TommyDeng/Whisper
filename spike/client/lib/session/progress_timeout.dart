import 'dart:async';

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
