/// 耳语 Whisper - Stage 3 主应用壳
///
/// 三个主屏：联系人列表、聊天、通话
/// 黑白/单色细线条风格，桌面端优先

import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'call_screen.dart';
import 'contacts_list.dart';
import '../contact/contact_model.dart';

/// 主应用
class WhisperApp extends StatefulWidget {
  const WhisperApp({super.key});

  @override
  State<WhisperApp> createState() => _WhisperAppState();
}

class _WhisperAppState extends State<WhisperApp> {
  int _selectedIndex = 0;

  static final _callContact = Contact(
    deviceId: 'local-device',
    name: '通话',
    x25519PublicKeyBase64: '',
    ed25519PublicKeyBase64: '',
    safetyCode: '',
    isVerified: true,
    createdAt: DateTime.now().millisecondsSinceEpoch,
    lastMessageTime: 0,
  );

  final List<Widget> _screens = [
    const ContactsListScreen(),
    const Placeholder(),
    CallScreen(contactName: '通话', contact: _callContact),
  ];

  final List<String> _titles = [
    '联系人',
    '聊天',
    '通话',
  ];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '耳语 Whisper',
      theme: AppTheme.light,
      home: Scaffold(
        // 联系人页和通话页自带标题栏，这里只给没有标题栏的页面补一个
        appBar: _selectedIndex == 1 ? AppBar(title: Text(_titles[_selectedIndex])) : null,
        body: _screens[_selectedIndex],
        bottomNavigationBar: _buildBottomNavigation(),
      ),
    );
  }

  Widget _buildBottomNavigation() {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: AppTheme.white,
        border: Border(
          top: BorderSide(color: AppTheme.lightGray, width: 1),
        ),
      ),
      child: Row(
        children: [
          _buildNavItem(0, '联系人', Icons.people_outline, Icons.people),
          _buildNavItem(1, '聊天', Icons.chat_bubble_outline, Icons.chat_bubble),
          _buildNavItem(2, '通话', Icons.call_outlined, Icons.call),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    int index,
    String label,
    IconData inactiveIcon,
    IconData activeIcon,
  ) {
    final isSelected = _selectedIndex == index;
    final List<IconData> _inactiveIcons = [
      Icons.people_outline,
      Icons.chat_bubble_outline,
      Icons.call_outlined,
    ];
    final List<IconData> _activeIcons = [
      Icons.people,
      Icons.chat_bubble,
      Icons.call,
    ];

    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedIndex = index;
          });
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? _activeIcons[index] : _inactiveIcons[index],
              size: 20,
              color: isSelected ? AppTheme.black : AppTheme.midGray,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? AppTheme.black : AppTheme.midGray,
                fontSize: 10,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 占位页（待实现）
class Placeholder extends StatelessWidget {
  const Placeholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.info_outline,
            size: 48,
            color: AppTheme.midGray,
          ),
          const SizedBox(height: 12),
          Text(
            '功能开发中',
            style: const TextStyle(
              color: AppTheme.darkGray,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}
