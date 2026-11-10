/// 耳语 Whisper - Stage 3 极简线条风主题
///
/// 黑白/单色细线条风格，留白多，无头像墙、无红点轰炸。

import 'package:flutter/material.dart';

/// 应用主题色（纯黑白灰，无彩色）
class AppTheme {
  static const Color black = Color(0xFF1A1A1A);
  static const Color darkGray = Color(0xFF4A4A4A);
  static const Color midGray = Color(0xFF8A8A8A);
  static const Color lightGray = Color(0xFFD9D9D9);
  static const Color white = Color(0xFFFFFFFF);
  static const Color surface = Color(0xFFF5F5F5);

  /// 错误提示颜色
  static const Color red = Color(0xFFB00020);

  /// 安全状态颜色：已验证=深绿灰，未验证=琥珀色
  static const Color securityVerified = Color(0xFF4A4A4A);
  static const Color securityUnverified = Color(0xFF8A8A8A);

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
        titleTextStyle: TextStyle(color: black, fontSize: 18, fontWeight: FontWeight.w500),
      ),
      cardColor: surface,
      dividerColor: lightGray,
      fontFamily: 'Inter',
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
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: lightGray, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: lightGray, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
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
            borderRadius: BorderRadius.circular(4),
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
            borderRadius: BorderRadius.circular(4),
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
            borderRadius: BorderRadius.circular(4),
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
