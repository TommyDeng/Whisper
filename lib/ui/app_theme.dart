/// 耳语 Whisper - Stage 3 极简线条风主题
///
/// 黑白/单色细线条风格，留白多，无头像墙、无红点轰炸。
/// 颜色只用来传达状态：绿＝在线 / 已验证 / 通话中，琥珀＝未验证，红＝出错或挂断。

import 'package:flutter/material.dart';

/// 应用主题色：黑白灰打底，另有三个只表示状态的颜色。
class AppTheme {
  static const Color black = Color(0xFF1A1A1A);
  static const Color darkGray = Color(0xFF4A4A4A);
  static const Color midGray = Color(0xFF8A8A8A);
  static const Color lightGray = Color(0xFFE2E2E2);
  static const Color white = Color(0xFFFFFFFF);
  static const Color surface = Color(0xFFF4F4F3);

  /// 鼠标悬停在可点的行上时的底色。
  static const Color hover = Color(0xFFF0F0EF);

  /// 在线、已验证、通话接通。
  static const Color green = Color(0xFF2F7D5B);

  /// [green] 的浅底，衬在图标后面。
  static const Color greenTint = Color(0xFFE6F1EC);

  /// 未验证：需要留意，但不是错误。
  static const Color amber = Color(0xFFB7791F);

  /// 中文字体兜底。没有打包 Inter，不写这个的话各平台回退到的中文字体不一样。
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

  static const double radius = 8;

  /// 错误提示颜色
  static const Color red = Color(0xFFB00020);

  /// 安全状态颜色：已验证=绿，未验证=琥珀色
  static const Color securityVerified = green;
  static const Color securityUnverified = amber;

  static ThemeData get light {
    return ThemeData(
      useMaterial3: false,
      brightness: Brightness.light,
      scaffoldBackgroundColor: white,
      // 主色用黑色：按钮、光标、进度圈都跟着单色风格走
      colorScheme: const ColorScheme.light(
        primary: black,
        onPrimary: white,
        secondary: black,
        onSecondary: white,
        error: red,
      ),
      // 白底标题栏必须配深色前景，否则标题和返回箭头是白字白底，看不见
      appBarTheme: const AppBarTheme(
        backgroundColor: white,
        foregroundColor: black,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: black, size: 20),
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: black,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          fontFamilyFallback: fontFallback,
        ),
      ),
      cardColor: surface,
      dividerColor: lightGray,
      fontFamily: 'Inter',
      fontFamilyFallback: fontFallback,
      // 桌面端不要水波纹，悬停和按下只换底色。
      splashFactory: NoSplash.splashFactory,
      hoverColor: hover,
      highlightColor: const Color(0x0A000000),
      focusColor: const Color(0x0F000000),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: black),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: black,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: const TextStyle(color: white, fontSize: 12),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: white,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        titleTextStyle: const TextStyle(
          color: black,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          fontFamilyFallback: fontFallback,
        ),
        contentTextStyle: const TextStyle(
          color: darkGray,
          fontSize: 14,
          height: 1.5,
          fontFamilyFallback: fontFallback,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: white,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: lightGray),
        ),
        textStyle: const TextStyle(
          color: black,
          fontSize: 14,
          fontFamilyFallback: fontFallback,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: black,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        contentTextStyle: const TextStyle(
          color: white,
          fontSize: 13,
          fontFamilyFallback: fontFallback,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(6),
        radius: const Radius.circular(3),
        thumbColor: WidgetStateProperty.all(const Color(0x33000000)),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          color: black,
          fontSize: 32,
          fontWeight: FontWeight.w400,
          letterSpacing: -0.5,
        ),
        displayMedium: TextStyle(
          color: black,
          fontSize: 28,
          fontWeight: FontWeight.w400,
          letterSpacing: -0.5,
        ),
        headlineLarge: TextStyle(
          color: black,
          fontSize: 24,
          fontWeight: FontWeight.w400,
        ),
        headlineMedium: TextStyle(
          color: black,
          fontSize: 20,
          fontWeight: FontWeight.w400,
        ),
        titleLarge: TextStyle(
          color: black,
          fontSize: 18,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: TextStyle(
          color: black,
          fontSize: 16,
          fontWeight: FontWeight.w400,
        ),
        bodyMedium: TextStyle(
          color: black,
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
        bodySmall: TextStyle(
          color: darkGray,
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
        labelLarge: TextStyle(
          color: black,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      iconTheme: const IconThemeData(
        color: black,
        size: 20,
      ),
      dividerTheme: const DividerThemeData(
        color: lightGray,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: lightGray, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: lightGray, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: black, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: black,
          foregroundColor: white,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: black,
          elevation: 0,
          shadowColor: Colors.transparent,
          side: const BorderSide(color: black, width: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: black,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 安全状态
enum SecurityStatus {
  verified,
  unverified,
}

/// 安全状态图标：简单线条图标，常驻显示
class SecurityIcon extends StatelessWidget {
  final SecurityStatus status;
  final double size;

  const SecurityIcon({
    super.key,
    required this.status,
    this.size = 16,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: status == SecurityStatus.verified
            ? AppTheme.securityVerified
            : AppTheme.securityUnverified,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Icon(
          status == SecurityStatus.verified ? Icons.done : Icons.error_outline,
          size: size * 0.6,
          color: AppTheme.white,
        ),
      ),
    );
  }
}

/// 联系人的字标：细线圆圈里放名字的第一个字，在线时右下角有个绿点。
///
/// 不是头像——没有图片、没有颜色区分，只是让列表有个可以落眼的地方。
class ContactMark extends StatelessWidget {
  const ContactMark({
    super.key,
    required this.name,
    this.online = false,
    this.size = 36,
  });

  final String name;
  final bool online;
  final double size;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty
        ? '?'
        : String.fromCharCodes(trimmed.runes.take(1)).toUpperCase();
    final dot = size * 0.3;
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
              color: AppTheme.white,
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.black, width: 1),
            ),
            child: Text(
              initial,
              style: TextStyle(
                color: AppTheme.black,
                fontSize: size * 0.42,
                fontWeight: FontWeight.w500,
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
                  color: AppTheme.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppTheme.white, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
