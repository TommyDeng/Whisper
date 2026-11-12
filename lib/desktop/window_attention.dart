/// 任务栏闪烁：窗口隐藏或失去焦点时，用原生通道提醒用户有新消息。
library;

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
