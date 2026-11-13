/// 桌面窗口：单实例由原生层处理；这里负责关到托盘、托盘菜单和焦点状态。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
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

  static String get _normalIcon => Platform.isWindows
      ? 'assets/icons/app_icon.ico'
      : 'assets/icons/whisper.png';
  static String get _alertIcon => Platform.isWindows
      ? 'assets/icons/app_icon_unread.ico'
      : 'assets/icons/whisper_unread.png';
  static String get _blankIcon => Platform.isWindows
      ? 'assets/icons/app_icon_blank.ico'
      : 'assets/icons/whisper_blank.png';

  /// 有未看的新消息时让托盘图标闪烁。
  late final _blinker = TrayBlinker(
    setIcon: trayManager.setIcon,
    normalIcon: _normalIcon,
    alertIcon: _alertIcon,
    blankIcon: _blankIcon,
  );

  /// 初始化窗口拦截和托盘。只在 Linux / Windows 上有效。
  Future<void> init() async {
    if (_ready) return;
    if (!(Platform.isLinux || Platform.isWindows)) return;
    kDesktopChannel.setMethodCallHandler(_onNativeCall);
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    trayManager.addListener(this);
    await _initTray();
    _ready = true;
    await refreshFocus();
  }

  /// 托盘图标和菜单。任一步失败都不能耽误后面的菜单注册。
  ///
  /// Linux 的 tray_manager 没有实现 `setToolTip`；1.0.3 在 setIcon 之后调用它
  /// 会抛错，导致 [setContextMenu] 根本没跑，托盘图标在、菜单却是空的。
  Future<void> _initTray() async {
    try {
      await trayManager.setIcon(_normalIcon);
    } catch (_) {}
    try {
      await trayManager.setToolTip('耳语');
    } catch (_) {}
    try {
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: '显示'),
            MenuItem(key: 'quit', label: '退出'),
          ],
        ),
      );
    } catch (_) {}
  }

  Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'quit':
        await quit();
      case 'show':
        await showMainWindow();
    }
  }

  /// 把主窗口请到前台（第二次启动或托盘「显示」）。
  Future<void> showMainWindow() async {
    _blinker.stop();
    await windowManager.show();
    await windowManager.focus();
    focus.windowHidden = false;
    focus.windowFocused = true;
  }

  /// 真正退出：取消关到托盘，拆掉托盘图标。
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    _blinker.stop();
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

  /// 根据窗口是否可见、是否在前台，决定要不要闪任务栏和托盘图标。
  ///
  /// 托盘图标一直闪到窗口重新回到前台（[onWindowFocus] / [showMainWindow]）。
  Future<void> flashIfNeeded() async {
    await refreshFocus();
    if (_ready &&
        shouldFlashTaskbar(
          windowFocused: focus.windowFocused,
          windowHidden: focus.windowHidden,
        )) {
      _blinker.start();
    }
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
    _blinker.stop();
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
    // Windows 左键直接显示窗口；Linux 的 AppIndicator 会在点击时弹出已设置的菜单，
    // 且 popUpContextMenu 在 Linux 上不可用。
    if (Platform.isWindows) {
      unawaited(showMainWindow());
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    if (Platform.isWindows) {
      unawaited(trayManager.popUpContextMenu());
    }
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
