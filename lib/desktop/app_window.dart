/// 桌面窗口：单实例由原生层处理；这里负责关到托盘、托盘菜单和焦点状态。
library;

import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../ui/ui_focus.dart';
import 'window_attention.dart';

/// 托盘和关闭行为。测试里不要调用 [init]，避免插件通道。
class AppWindow with WindowListener, TrayListener {
  AppWindow(this.focus);

  final UiFocus focus;
  var _ready = false;
  var _quitting = false;

  /// 初始化窗口拦截和托盘。只在 Linux / Windows 上有效。
  Future<void> init() async {
    if (_ready) return;
    if (!(Platform.isLinux || Platform.isWindows)) return;
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    trayManager.addListener(this);
    final icon = Platform.isWindows
        ? 'assets/icons/app_icon.ico'
        : 'assets/icons/whisper.png';
    await trayManager.setIcon(icon);
    await trayManager.setToolTip('耳语');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: '显示'),
          MenuItem(key: 'quit', label: '退出'),
        ],
      ),
    );
    _ready = true;
    await refreshFocus();
  }

  /// 把主窗口请到前台（第二次启动或托盘「显示」）。
  Future<void> showMainWindow() async {
    await windowManager.show();
    await windowManager.focus();
    focus.windowHidden = false;
    focus.windowFocused = true;
  }

  /// 真正退出：取消关到托盘，拆掉托盘图标。
  Future<void> quit() async {
    _quitting = true;
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    try {
      await trayManager.destroy();
    } catch (_) {}
    try {
      await windowManager.destroy();
    } catch (_) {}
  }

  /// 根据窗口是否可见、是否在前台，决定要不要闪任务栏。
  Future<void> flashIfNeeded() async {
    await refreshFocus();
    await flashTaskbarIfNeeded(focus);
  }

  /// 把原生窗口状态同步到 [focus]。
  Future<void> refreshFocus() async {
    if (!_ready) return;
    try {
      final visible = await windowManager.isVisible();
      final minimized = await windowManager.isMinimized();
      final focused = await windowManager.isFocused();
      focus.windowHidden = !visible || minimized;
      focus.windowFocused = focused && visible && !minimized;
    } catch (_) {}
  }

  @override
  void onWindowClose() {
    if (_quitting) return;
    unawaited(
      windowManager.hide().then((_) {
        focus.windowHidden = true;
        focus.windowFocused = false;
      }),
    );
  }

  @override
  void onWindowFocus() {
    focus.windowFocused = true;
    focus.windowHidden = false;
  }

  @override
  void onWindowBlur() {
    focus.windowFocused = false;
  }

  @override
  void onWindowMinimize() {
    focus.windowHidden = true;
    focus.windowFocused = false;
  }

  @override
  void onWindowRestore() {
    focus.windowHidden = false;
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(showMainWindow());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      unawaited(showMainWindow());
    } else if (menuItem.key == 'quit') {
      unawaited(quit());
    }
  }
}
