/// 动效：按钮的悬停 / 按下、对话框弹出、聊天区切换。
///
/// 全应用的按钮都走这里的两套外观：
/// - Material 按钮（Filled / Outlined / Text）由 [AppTheme] 的 ButtonStyle 调 [ButtonSkin]；
/// - 图标按钮用 [TermIconButton] 和 [SquareIconButton]，底下都是 [Pressable]。
/// 两套的手感一样：悬停变亮、按下缩小一点、松开弹回。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';

/// 动效时长和曲线。
abstract final class Motion {
  /// 悬停、按下的颜色和缩放。
  static const Duration fast = Duration(milliseconds: 110);

  /// 对话框、聊天区切换。
  static const Duration medium = Duration(milliseconds: 200);

  static const Curve curve = Curves.easeOutCubic;

  /// 按下时缩到多大。
  static const double pressedScale = 0.94;

  /// 按下状态至少保持这么久，快速点击也能看到「按下去再弹起来」。
  static const Duration minPress = Duration(milliseconds: 90);
}

/// Material 按钮的外观：底色、描边、按下缩放。
///
/// 由 [AppTheme] 里各档 ButtonStyle 的 `backgroundBuilder` 调用；按钮本身的 Material
/// 是透明的，看得见的部分全在这里画，所以缩放的是整个按钮而不只是文字。
class ButtonSkin extends StatelessWidget {
  const ButtonSkin({
    super.key,
    required this.states,
    required this.fill,
    required this.side,
    required this.child,
  });

  final Set<WidgetState> states;

  /// 平时的底色；透明表示描边按钮。
  final Color fill;
  final Color side;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final disabled = states.contains(WidgetState.disabled);
    final pressed = !disabled && states.contains(WidgetState.pressed);
    final hovered =
        !disabled &&
        (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused));
    final outlined = fill.a == 0;

    final Color background;
    final Color border;
    if (disabled) {
      background = outlined ? Colors.transparent : AppTheme.raised;
      border = AppTheme.divider;
    } else if (outlined) {
      // 描边按钮：悬停时铺一层描边色的淡底，按下再深一点。
      final tint = side == AppTheme.border ? AppTheme.text2 : side;
      background = pressed
          ? tint.withValues(alpha: 0.20)
          : hovered
          ? tint.withValues(alpha: 0.10)
          : Colors.transparent;
      border = hovered || pressed ? tint : side;
    } else {
      // 实心按钮：悬停提亮，按下压暗。
      background = pressed
          ? Color.lerp(fill, Colors.black, 0.18)!
          : hovered
          ? Color.lerp(fill, Colors.white, 0.18)!
          : fill;
      border = background;
    }

    return AnimatedScale(
      scale: pressed ? Motion.pressedScale : 1,
      duration: Motion.fast,
      curve: Motion.curve,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        decoration: BoxDecoration(
          color: background,
          borderRadius: AppTheme.corners,
          border: Border.all(color: border),
        ),
        child: child,
      ),
    );
  }
}

/// 自己画外观的可点控件：管悬停、按下、键盘激活，外观交给 [builder]。
///
/// 按下时整体缩小一点，松开弹回；[onPressed] 为 null 时不可点、不响应悬停。
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.onPressed,
    required this.builder,
    this.onSecondaryTapUp,
  });

  final VoidCallback? onPressed;
  final GestureTapUpCallback? onSecondaryTapUp;

  /// 按状态画外观；状态里可能有 hovered、pressed、focused、disabled。
  final Widget Function(BuildContext context, Set<WidgetState> states) builder;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;
  DateTime? _pressedAt;
  Timer? _release;

  bool get _enabled => widget.onPressed != null;

  @override
  void didUpdateWidget(Pressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled) {
      _hovered = false;
      _pressed = false;
    }
  }

  @override
  void dispose() {
    _release?.cancel();
    super.dispose();
  }

  void _down() {
    if (!_enabled) return;
    _release?.cancel();
    _pressedAt = DateTime.now();
    setState(() => _pressed = true);
  }

  /// 松开：按下不到 [Motion.minPress] 的话等一等再弹起，快速点击也有动作。
  void _up() {
    final at = _pressedAt;
    _pressedAt = null;
    if (at == null) return;
    final left = Motion.minPress - DateTime.now().difference(at);
    if (left <= Duration.zero) {
      if (mounted) setState(() => _pressed = false);
      return;
    }
    _release = Timer(left, () {
      if (mounted && _pressedAt == null) setState(() => _pressed = false);
    });
  }

  void _activate() {
    _down();
    _up();
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final states = <WidgetState>{
      if (!_enabled) WidgetState.disabled,
      if (_enabled && _hovered) WidgetState.hovered,
      if (_enabled && _focused) WidgetState.focused,
      if (_enabled && _pressed) WidgetState.pressed,
    };
    return Semantics(
      button: true,
      enabled: _enabled,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled ? (_) => _down() : null,
          onTapUp: _enabled ? (_) => _up() : null,
          onTapCancel: _enabled ? _up : null,
          onTap: widget.onPressed,
          onSecondaryTapUp: widget.onSecondaryTapUp,
          child: AnimatedScale(
            scale: states.contains(WidgetState.pressed)
                ? Motion.pressedScale
                : 1,
            duration: Motion.fast,
            curve: Motion.curve,
            child: widget.builder(context, states),
          ),
        ),
      ),
    );
  }
}

/// 无底色的图标按钮：标题栏、输入栏、对话框关闭键。
///
/// 悬停时铺一层浅底、图标变亮，按下缩小。替代 Material 2 的 IconButton
/// （它不认 ButtonStyle，没法和别的按钮做成一样的手感）。
class TermIconButton extends StatelessWidget {
  const TermIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 36,
    this.iconSize = 20,
    this.color = AppTheme.text2,
    this.hoverColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;

  /// 平时的图标颜色。
  final Color color;

  /// 悬停时的图标颜色；不给的话普通灰图标变成正文色，有颜色的保持原色。
  final Color? hoverColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Pressable(
        onPressed: onPressed,
        builder: (context, states) {
          final disabled = states.contains(WidgetState.disabled);
          final active =
              states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed);
          final Color fg = disabled
              ? AppTheme.text3
              : active
              ? (hoverColor ??
                    (color == AppTheme.text2 ? AppTheme.text : color))
              : color;
          return AnimatedContainer(
            duration: Motion.fast,
            curve: Motion.curve,
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: states.contains(WidgetState.pressed)
                  ? AppTheme.accentSoft
                  : active
                  ? AppTheme.hover
                  : Colors.transparent,
              borderRadius: AppTheme.corners,
              border: Border.all(
                color: active ? AppTheme.border : Colors.transparent,
              ),
            ),
            child: Center(
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: fg),
                duration: Motion.fast,
                builder: (context, value, _) =>
                    Icon(icon, size: iconSize, color: value),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 弹出终端风格的对话框：淡入、从略小放大到原大、略微上移。
///
/// 用法和 [showDialog] 一样；所有对话框都走这里，进出场动作统一。
Future<T?> showTermDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: AppTheme.scrim,
    transitionDuration: Motion.medium,
    pageBuilder: (context, animation, secondaryAnimation) =>
        SafeArea(child: Builder(builder: builder)),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        TermPopTransition(animation: animation, child: child),
  );
}

/// 对话框和大图查看的进出场：淡入 + 放大 + 上移 8px。
class TermPopTransition extends StatelessWidget {
  const TermPopTransition({
    super.key,
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Motion.curve,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.015),
          end: Offset.zero,
        ).animate(curved),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.95, end: 1).animate(curved),
          child: child,
        ),
      ),
    );
  }
}

/// 聊天区换人、单栏进出聊天时的过渡：新内容淡入并从右边滑进来一点。
class PaneSwitcher extends StatelessWidget {
  const PaneSwitcher({super.key, required this.child});

  /// 要换内容时给它换一个 key。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: Motion.medium,
      switchInCurve: Motion.curve,
      switchOutCurve: Curves.easeInCubic,
      // 旧内容直接叠在下面淡出，不和新内容抢位置。
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [
          for (final old in previous) IgnorePointer(child: old),
          ?current,
        ],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.02, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
