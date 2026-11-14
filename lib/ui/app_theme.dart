/// 耳语 Whisper - 霓虹终端主题
///
/// 近黑底、荧光绿主色、直角细描边加辉光。全应用只有这一套，不分浅色深色。
/// 颜色各管一件事：绿＝正常和可点，黄＝需要留意，红＝警告和危险。
/// 设计说明见 docs/ui-cyber-terminal.md。
library;

import 'package:flutter/material.dart';

import 'motion.dart';

export 'motion.dart';

/// 应用主题：所有颜色都在这里，别的文件不写颜色字面值。
class AppTheme {
  /// 聊天区和空状态的背景。
  static const Color bg = Color(0xFF05080A);

  /// 边栏、标题栏、通话条、对话框、菜单。
  static const Color panel = Color(0xFF080C0E);

  /// 输入框、文件卡、等待条。
  static const Color field = Color(0xFF0A1114);

  /// 收到的气泡、悬停提示。
  static const Color raised = Color(0xFF0C1417);

  /// 输入框、卡片、对话框、普通按钮的 1px 边。
  static const Color border = Color(0xFF1D3A33);

  /// 栏与栏之间、标题栏下方的线，进度条的底。
  static const Color divider = Color(0xFF16302A);

  /// 主色：主按钮、选中、自己发的气泡描边、在线、已验证。
  static const Color accent = Color(0xFF00F5A0);

  /// 主色的暗底：选中行、在线头像、邀请码块。
  static const Color accentSoft = Color(0xFF0B2A22);

  /// 主色底上的字和图标。
  static const Color onAccent = Color(0xFF04110D);

  /// 自己发的气泡。
  static const Color sentBg = Color(0xFF06241C);
  static const Color sentText = Color(0xFFB8FFE3);

  /// 警告和危险：未读数、来电、挂断、失败、不可恢复的操作。
  static const Color alert = Color(0xFFFF3B3B);
  static const Color alertSoft = Color(0xFF2A0C0C);
  static const Color alertBorder = Color(0xFF4A1616);
  static const Color onAlert = Color(0xFF140303);

  /// 需要留意但不是错误：未验证、重连中、有新版本。
  static const Color amber = Color(0xFFFFD23F);

  /// 正文。
  static const Color text = Color(0xFFD9F7EC);

  /// 选中行里的名字，比正文再亮一点。
  static const Color textBright = Color(0xFFEFFFF8);

  /// 副标题、说明、普通图标。
  static const Color text2 = Color(0xFF6FA595);

  /// 占位字、指纹、离线头像、装饰标签。对比度低，只用在不读也不影响使用的地方。
  static const Color text3 = Color(0xFF3F6B60);

  /// 鼠标悬停在可点的行上时的底色。
  static const Color hover = Color(0xFF0C1A17);

  /// 对话框后面的遮罩、大图查看的背景。
  static const Color scrim = Color(0xCC05080A);

  static const Color securityVerified = accent;
  static const Color securityUnverified = amber;

  /// 主色辉光：主按钮、自己发的气泡、聚焦的输入框、进度条。
  static const List<BoxShadow> glow = [
    BoxShadow(color: Color(0x4700F5A0), blurRadius: 12),
  ];

  /// 警告红辉光：红底按钮。
  static const List<BoxShadow> alertGlow = [
    BoxShadow(color: Color(0x52FF3B3B), blurRadius: 12),
  ];

  /// 对话框和菜单的投影。
  static const List<BoxShadow> popupShadow = [
    BoxShadow(color: Color(0x99000000), blurRadius: 60, offset: Offset(0, 24)),
  ];

  /// 全部圆角都是它；验证徽章除外，保持圆形。
  static const double radius = 2;
  static const BorderRadius corners = BorderRadius.all(Radius.circular(radius));

  static const String fontFamily = 'Inter';
  static const String monoFamily = 'JetBrains Mono';

  /// 中文字体兜底。没有打包中文字体，不写这个的话各平台回退到的中文字体不一样。
  static const List<String> fontFallback = [
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
  ];

  /// 等宽数字：通话时长、字节数跳动时不左右晃。
  static const List<FontFeature> tabularFigures = [
    FontFeature.tabularFigures(),
  ];

  /// 等宽字：指纹、邀请码、安全码、时长、文件大小、装饰标签。
  static TextStyle mono({
    Color color = text2,
    double size = 12,
    FontWeight weight = FontWeight.w400,
    double? letterSpacing,
    double? height,
  }) {
    return TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: fontFallback,
      color: color,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: letterSpacing,
      height: height,
      fontFeatures: tabularFigures,
    );
  }

  /// 装饰标签，例如 `WHISPER_`、`// 添加对方`。
  static TextStyle tag({Color color = accent}) =>
      mono(color: color, size: 10, weight: FontWeight.w500, letterSpacing: 1);

  static const RoundedRectangleBorder _shape = RoundedRectangleBorder(
    borderRadius: corners,
  );

  static const TextStyle _buttonText = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    fontFamily: fontFamily,
    fontFamilyFallback: fontFallback,
  );

  static ButtonStyle _button({
    required Color background,
    required Color foreground,
    required Color side,
  }) {
    // 底色和描边由 [ButtonSkin] 画（按下时连同外框一起缩小），Material 本身透明。
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.all(Colors.transparent),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return text3;
        // 普通按钮悬停时字变亮，和图标按钮一致。
        if (foreground == text2 &&
            (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.pressed))) {
          return text;
        }
        return foreground;
      }),
      side: WidgetStateProperty.all(BorderSide.none),
      overlayColor: WidgetStateProperty.all(Colors.transparent),
      elevation: WidgetStateProperty.all(0),
      shadowColor: WidgetStateProperty.all(Colors.transparent),
      shape: WidgetStateProperty.all(_shape),
      minimumSize: WidgetStateProperty.all(const Size(0, 36)),
      padding: WidgetStateProperty.all(
        const EdgeInsets.symmetric(horizontal: 16),
      ),
      textStyle: WidgetStateProperty.all(_buttonText),
      iconSize: WidgetStateProperty.all(16),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      animationDuration: Motion.fast,
      mouseCursor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
      ),
      backgroundBuilder: (context, states, child) => ButtonSkin(
        states: states,
        fill: background,
        side: side,
        child: child,
      ),
    );
  }

  /// 主按钮：一个界面里最该点的那个。
  static final ButtonStyle primaryButton = _button(
    background: accent,
    foreground: onAccent,
    side: accent,
  );

  /// 次按钮：主色边，没有底。
  static final ButtonStyle secondaryButton = _button(
    background: Colors.transparent,
    foreground: accent,
    side: accent,
  );

  /// 普通按钮：取消、关闭。
  static final ButtonStyle plainButton = _button(
    background: Colors.transparent,
    foreground: text2,
    side: border,
  );

  /// 危险按钮：拒绝、拒接。
  static final ButtonStyle dangerButton = _button(
    background: Colors.transparent,
    foreground: alert,
    side: alert,
  );

  /// 危险确认：挂断、不可恢复操作的确认键。
  static final ButtonStyle dangerFilledButton = _button(
    background: alert,
    foreground: onAlert,
    side: alert,
  );

  static OutlineInputBorder _inputBorder(Color color) => OutlineInputBorder(
    borderRadius: corners,
    borderSide: BorderSide(color: color, width: 1),
  );

  static ThemeData get dark {
    const base = TextStyle(
      color: text,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFallback,
    );
    return ThemeData(
      useMaterial3: false,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      canvasColor: panel,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        onPrimary: onAccent,
        secondary: accent,
        onSecondary: onAccent,
        surface: panel,
        onSurface: text,
        error: alert,
        onError: onAlert,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: panel,
        foregroundColor: text,
        elevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: text2, size: 20),
        scrolledUnderElevation: 0,
        titleTextStyle: base.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardColor: field,
      dividerColor: divider,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFallback,
      // 桌面端不要水波纹，悬停和按下只换底色。
      splashFactory: NoSplash.splashFactory,
      hoverColor: hover,
      highlightColor: const Color(0x0FFFFFFF),
      focusColor: const Color(0x14FFFFFF),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: divider,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: Color(0x5500F5A0),
        selectionHandleColor: accent,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: raised,
          borderRadius: corners,
          border: Border.all(color: border),
        ),
        textStyle: base.copyWith(fontSize: 12),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: panel,
        elevation: 0,
        barrierColor: scrim,
        shape: const RoundedRectangleBorder(
          borderRadius: corners,
          side: BorderSide(color: border),
        ),
        titleTextStyle: base.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: base.copyWith(
          color: text2,
          fontSize: 13.5,
          height: 1.6,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: panel,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: corners,
          side: BorderSide(color: border),
        ),
        textStyle: base.copyWith(fontSize: 13.5),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: accentSoft,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: corners,
          side: BorderSide(color: accent),
        ),
        contentTextStyle: base.copyWith(fontSize: 13),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(6),
        radius: const Radius.circular(radius),
        thumbColor: WidgetStateProperty.all(border),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? accent : text3,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? accentSoft : field,
        ),
      ),
      textTheme: TextTheme(
        displayLarge: base.copyWith(fontSize: 32, letterSpacing: -0.5),
        displayMedium: base.copyWith(fontSize: 28, letterSpacing: -0.5),
        headlineLarge: base.copyWith(fontSize: 24),
        headlineMedium: base.copyWith(fontSize: 20),
        titleLarge: base.copyWith(fontSize: 18, fontWeight: FontWeight.w500),
        titleMedium: base.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
        bodyLarge: base.copyWith(fontSize: 16),
        bodyMedium: base.copyWith(fontSize: 14),
        bodySmall: base.copyWith(color: text2, fontSize: 12),
        labelLarge: base.copyWith(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      iconTheme: const IconThemeData(color: text2, size: 20),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: text2,
          shape: _shape,
          hoverColor: hover,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: divider,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: field,
        hoverColor: Colors.transparent,
        hintStyle: base.copyWith(color: text3, fontSize: 14),
        labelStyle: base.copyWith(color: text2, fontSize: 13),
        floatingLabelStyle: base.copyWith(color: accent, fontSize: 13),
        border: _inputBorder(border),
        enabledBorder: _inputBorder(border),
        disabledBorder: _inputBorder(divider),
        focusedBorder: _inputBorder(accent),
        errorBorder: _inputBorder(alert),
        focusedErrorBorder: _inputBorder(alert),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
      ),
      // 四种 Material 按钮对应四档：Filled / Elevated＝主，Outlined＝次，Text＝普通。
      // 危险的两档用 [dangerButton]、[dangerFilledButton] 单独指定。
      filledButtonTheme: FilledButtonThemeData(style: primaryButton),
      elevatedButtonTheme: ElevatedButtonThemeData(style: primaryButton),
      outlinedButtonTheme: OutlinedButtonThemeData(style: secondaryButton),
      textButtonTheme: TextButtonThemeData(style: plainButton),
    );
  }
}

/// 安全状态
enum SecurityStatus { verified, unverified }

/// 安全状态徽章：常驻显示。全应用唯一保持圆形的元素。
class SecurityIcon extends StatelessWidget {
  final SecurityStatus status;
  final double size;

  const SecurityIcon({super.key, required this.status, this.size = 16});

  @override
  Widget build(BuildContext context) {
    final verified = status == SecurityStatus.verified;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: verified
            ? AppTheme.securityVerified
            : AppTheme.securityUnverified,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Icon(
          verified ? Icons.done : Icons.priority_high,
          size: size * 0.7,
          color: verified ? AppTheme.onAccent : AppTheme.onAlert,
        ),
      ),
    );
  }
}

/// 联系人的字标：方框里放名字的第一个字。
///
/// 颜色只分在线和离线，不按人分色：在线是主色描边加右下角发光的小方点，离线是暗色。
class ContactMark extends StatelessWidget {
  const ContactMark({
    super.key,
    required this.name,
    this.online = false,
    this.size = 40,
    this.ring = AppTheme.panel,
  });

  final String name;
  final bool online;
  final double size;

  /// 小方点外面那圈的颜色，要和字标所在的底色一样。
  final Color ring;

  /// 字标的前景色（描边和字）。测试用它确认颜色只跟在线状态有关。
  static Color foregroundFor({required bool online}) =>
      online ? AppTheme.accent : AppTheme.text3;

  /// 字标的底色。
  static Color backgroundFor({required bool online}) =>
      online ? AppTheme.accentSoft : AppTheme.raised;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty
        ? '?'
        : String.fromCharCodes(trimmed.runes.take(1)).toUpperCase();
    final fg = foregroundFor(online: online);
    final dot = (size * 0.3).clamp(8.0, 12.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: backgroundFor(online: online),
              borderRadius: AppTheme.corners,
              border: Border.all(color: fg, width: 1),
            ),
            child: Text(
              initial,
              style: TextStyle(
                color: fg,
                fontSize: size * 0.42,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ),
          if (online)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  color: AppTheme.accent,
                  borderRadius: AppTheme.corners,
                  border: Border.all(color: ring, width: 2),
                  boxShadow: AppTheme.glow,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 对话框标题旁、分组上方的等宽装饰标签。
class TagLabel extends StatelessWidget {
  const TagLabel(this.label, {super.key, this.color = AppTheme.accent});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Text(label, style: AppTheme.tag(color: color));
}

/// 终端风格的对话框：标题栏（标题 + 装饰标签 + 关闭）、内容、右对齐的按钮。
///
/// [tag] 是标题旁的装饰：`PAIR_`、`VERIFY_`、`ABOUT_`、`CONFIRM_`、`DANGER_`。
class TermDialog extends StatelessWidget {
  const TermDialog({
    super.key,
    required this.title,
    required this.tag,
    required this.content,
    this.actions = const [],
    this.width = 440,
    this.onClose,
  });

  final String title;
  final String tag;
  final Widget content;
  final List<Widget> actions;
  final double width;

  /// 右上角关闭按钮做的事；不给就是关掉对话框、不带返回值。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        constraints: BoxConstraints(maxWidth: width),
        decoration: const BoxDecoration(boxShadow: AppTheme.popupShadow),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.only(left: 20, right: 6),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.divider)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 标题和标签靠左占满，关闭按钮贴右边。
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            style: theme.dialogTheme.titleTextStyle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: TagLabel(tag),
                        ),
                      ],
                    ),
                  ),
                  TermIconButton(
                    tooltip: '关闭',
                    icon: Icons.close,
                    iconSize: 16,
                    size: 32,
                    onPressed: onClose ?? () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: DefaultTextStyle(
                  style:
                      theme.dialogTheme.contentTextStyle ??
                      const TextStyle(color: AppTheme.text2),
                  child: content,
                ),
              ),
            ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 10,
                  runSpacing: 10,
                  children: actions,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 发光的细进度线。[value] 为 null 时是不确定进度。
class GlowProgress extends StatelessWidget {
  const GlowProgress({super.key, this.value, this.color = AppTheme.accent});

  final double? value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 3,
      child: LinearProgressIndicator(
        value: value,
        minHeight: 3,
        color: color,
        backgroundColor: AppTheme.divider,
      ),
    );
  }
}

/// 方形开关。开＝主色边、主色方块靠右；关＝暗边、暗方块靠左。
/// [onChanged] 为 null 时不可点。
class TermSwitch extends StatelessWidget {
  const TermSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final on = value && enabled;
    return Semantics(
      toggled: value,
      enabled: enabled,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? () => onChanged!(!value) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Container(
              width: 38,
              height: 20,
              padding: const EdgeInsets.all(2),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                color: on ? AppTheme.accentSoft : AppTheme.field,
                borderRadius: AppTheme.corners,
                border: Border.all(
                  color: on ? AppTheme.accent : AppTheme.border,
                ),
              ),
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: on ? AppTheme.accent : AppTheme.text3,
                  boxShadow: on ? AppTheme.glow : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 带底色和描边的方形图标按钮。
///
/// Material 2 的 IconButton 不认 `style`，要底色和描边就得自己画。
class SquareIconButton extends StatelessWidget {
  const SquareIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 36,
    this.iconSize = 18,
    this.background = AppTheme.accentSoft,
    this.foreground = AppTheme.accent,
    this.borderColor = AppTheme.accent,
    this.glow = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final Color background;
  final Color foreground;
  final Color borderColor;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Pressable(
        onPressed: onPressed,
        builder: (context, states) {
          final disabled = states.contains(WidgetState.disabled);
          final pressed = states.contains(WidgetState.pressed);
          final hovered =
              states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused);
          // 实心的悬停提亮、按下压暗；暗底的悬停换成更亮的暗底。
          final solid =
              background == AppTheme.accent || background == AppTheme.alert;
          final Color bg = disabled
              ? AppTheme.raised
              : pressed
              ? Color.lerp(background, Colors.black, 0.18)!
              : hovered
              ? Color.lerp(
                  background,
                  solid ? Colors.white : borderColor,
                  solid ? 0.18 : 0.12,
                )!
              : background;
          return AnimatedContainer(
            duration: Motion.fast,
            curve: Motion.curve,
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: AppTheme.corners,
              border: Border.all(
                color: disabled ? AppTheme.divider : borderColor,
              ),
              boxShadow: !disabled && (glow || hovered) && !pressed
                  ? (borderColor == AppTheme.alert
                        ? AppTheme.alertGlow
                        : AppTheme.glow)
                  : null,
            ),
            child: Icon(
              icon,
              size: iconSize,
              color: disabled ? AppTheme.text3 : foreground,
            ),
          );
        },
      ),
    );
  }
}
