/// 耳语 Whisper - 联系人列表界面
///
/// 主要界面之一：联系人列表
/// 黑白/单色细线条风格，无头像墙、无红点轰炸
// 安全状态（已验证/未验证）用简单线条图标常驻显示

import 'package:flutter/material.dart';
import 'app_theme.dart';

/// 联系人条目
class ContactItem extends StatelessWidget {
  final String name;
  final String deviceId;
  final SecurityStatus securityStatus;
  final bool isOnline;
  final String? lastMessage;
  final int? lastMessageTime;
  final VoidCallback onTap;

  const ContactItem({
    super.key,
    required this.name,
    required this.deviceId,
    required this.securityStatus,
    this.isOnline = false,
    this.lastMessage,
    this.lastMessageTime,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: AppTheme.lightGray, width: 1),
          ),
        ),
        child: Row(
          children: [
            // 安全状态图标（常驻显示）
            SecurityIcon(status: securityStatus, size: 14),
            const SizedBox(width: 12),
            // 联系人名称（无头像）
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      color: AppTheme.black,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (lastMessage != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      lastMessage!,
                      style: const TextStyle(
                        color: AppTheme.darkGray,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ],
                ],
              ),
            ),
            // 在线状态（简练点）
            if (isOnline)
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: AppTheme.black,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 联系人列表页面
class ContactsListScreen extends StatefulWidget {
  const ContactsListScreen({super.key});

  @override
  State<ContactsListScreen> createState() => _ContactsListScreenState();
}

class _ContactsListScreenState extends State<ContactsListScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '联系人',
          style: TextStyle(
            color: AppTheme.black,
            fontSize: 18,
            fontWeight: FontWeight.w500,
          ),
        ),
        centerTitle: false,
        elevation: 0,
        backgroundColor: AppTheme.white,
        leading: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.menu, size: 20),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.person_add, size: 20),
          ),
        ],
      ),
      body: Column(
        children: [
          // 分隔线
          const Divider(height: 1),
          // 空状态
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.people_outline,
                    size: 48,
                    color: AppTheme.midGray,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '暂无联系人',
                    style: const TextStyle(
                      color: AppTheme.darkGray,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '通过扫码或邀请码添加亲友',
                    style: const TextStyle(
                      color: AppTheme.midGray,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {},
        child: const Icon(Icons.person_add, size: 20),
      ),
    );
  }
}
