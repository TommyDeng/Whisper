/// 耳语 Whisper - 通话界面
///
/// 主要界面之一：1:1 E2EE 语音通话
/// 黑白/单色细线条风格，安全状态常驻显示

import 'package:flutter/material.dart';
import 'app_theme.dart';

/// 通话界面
class CallScreen extends StatefulWidget {
  final String contactName;

  const CallScreen({super.key, required this.contactName});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _isMuted = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.white,
      body: Column(
        children: [
          // 顶部状态栏区域
          Expanded(
            flex: 2,
            child: Column(
              children: [
                const SizedBox(height: 48),
                // 安全状态图标（常驻显示）
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SecurityIcon(status: SecurityStatus.unverified, size: 14),
                    const SizedBox(width: 8),
                    Text(
                      '连接路径：ZeroTier',
                      style: const TextStyle(
                        color: AppTheme.midGray,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 40),
                // 联系人名称
                Text(
                  widget.contactName,
                  style: const TextStyle(
                    color: AppTheme.black,
                    fontSize: 32,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '通话中',
                  style: const TextStyle(
                    color: AppTheme.darkGray,
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 48),
                // 通话时长
                Text(
                  '00:00',
                  style: const TextStyle(
                    color: AppTheme.black,
                    fontSize: 48,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -1,
                  ),
                ),
              ],
            ),
          ),
          // 底部控制区域
          Expanded(
            flex: 1,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 静音按钮
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppTheme.lightGray,
                      width: 1,
                    ),
                  ),
                  child: IconButton(
                    icon: Icon(
                      _isMuted ? Icons.mic_off : Icons.mic,
                      size: 24,
                    ),
                    onPressed: () {
                      setState(() {
                        _isMuted = !_isMuted;
                      });
                    },
                    color: AppTheme.black,
                    padding: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(height: 32),
                // 挂断按钮
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppTheme.black,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.call_end, size: 24),
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    color: AppTheme.white,
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
