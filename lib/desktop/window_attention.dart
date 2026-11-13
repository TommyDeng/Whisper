/// 新消息提醒：窗口隐藏或失去焦点时，闪任务栏按钮，并让托盘图标闪烁。
///
/// 托盘图标是整个一亮一灭（带红点的图标和空白图标交替）。1.0.4 是在普通图标和
/// 带红点图标之间交替，两张图只差角上一个红点，在托盘那么小的尺寸上看不出在闪。
///
/// 只闪任务栏按钮不够：关到托盘后窗口是隐藏的，没有按钮可闪；
/// Wayland 下 GTK 的紧急提示也不起作用。托盘图标在这两种情况下都还在。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../ui/ui_focus.dart';

/// 与 Linux / Windows 跑程序共用的方法通道。
const kDesktopChannel = MethodChannel('whisper/desktop');

/// 窗口不在前台或已经藏到托盘时，才需要闪任务栏。
bool shouldFlashTaskbar({
  required bool windowFocused,
  required bool windowHidden,
}) {
  return windowHidden || !windowFocused;
}

/// 调用原生闪烁。通道不可用时静默忽略。
Future<void> flashTaskbarIfNeeded(UiFocus focus) async {
  if (!shouldFlashTaskbar(
    windowFocused: focus.windowFocused,
    windowHidden: focus.windowHidden,
  )) {
    return;
  }
  try {
    await kDesktopChannel.invokeMethod<void>('flash');
  } on MissingPluginException {
    // 测试或尚未注册通道时不必闪。
  } catch (_) {}
}

/// 让托盘图标在带红点的提醒图标和空白图标之间交替，直到 [stop] 恢复普通图标。
class TrayBlinker {
  TrayBlinker({
    required this.setIcon,
    required this.normalIcon,
    required this.alertIcon,
    required this.blankIcon,
  });

  /// 两次换图标之间的间隔。
  static const interval = Duration(milliseconds: 600);

  final Future<void> Function(String icon) setIcon;
  final String normalIcon;
  final String alertIcon;

  /// 全透明的图标，闪烁中“灭”的那一拍。
  final String blankIcon;

  Timer? _timer;
  var _alertShown = false;

  bool get active => _timer != null;

  /// 开始闪烁；已经在闪就什么也不做。
  void start() {
    if (_timer != null) return;
    _alertShown = true;
    _set(alertIcon);
    _timer = Timer.periodic(interval, (_) {
      _alertShown = !_alertShown;
      _set(_alertShown ? alertIcon : blankIcon);
    });
  }

  /// 停止闪烁并恢复普通图标。
  void stop() {
    final timer = _timer;
    if (timer == null) return;
    timer.cancel();
    _timer = null;
    _alertShown = false;
    _set(normalIcon);
  }

  void _set(String icon) {
    // 托盘不可用时换图标会失败，不能让它变成未处理的异步错误。
    unawaited(Future<void>.sync(() => setIcon(icon)).catchError((Object _) {}));
  }
}
