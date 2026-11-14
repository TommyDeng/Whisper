/// 耳语 Whisper - 主应用壳
///
/// 首页是联系人列表加聊天的分栏；通话从聊天里发起。
/// 通话条（[CallHost]）在窗口顶部，不挡住聊天输入和发文件；来电时不管停在哪一页都能看到。
/// 霓虹终端风格，桌面端优先。
library;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'call_overlay.dart';
import 'contacts_list.dart';

class WhisperApp extends StatelessWidget {
  const WhisperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '耳语 Whisper',
      theme: AppTheme.dark,
      builder: (context, child) =>
          CallHost(child: child ?? const SizedBox.shrink()),
      home: const ContactsListScreen(),
    );
  }
}
