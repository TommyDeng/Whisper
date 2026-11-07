/// 耳语 Whisper - 聊天界面
///
/// 主要界面之一：1:1 E2EE 文字聊天
/// 黑白/单色细线条风格，安全状态常驻显示

import 'package:flutter/material.dart';
import 'app_theme.dart';

/// 聊天气泡
class ChatBubble extends StatelessWidget {
  final String text;
  final bool isSent;
  final bool isRead;
  final bool burnAfterRead;
  final SecurityStatus securityStatus;

  const ChatBubble({
    super.key,
    required this.text,
    required this.isSent,
    this.isRead = false,
    this.burnAfterRead = false,
    this.securityStatus = SecurityStatus.unverified,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: isSent
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisAlignment: isSent
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        // 安全状态图标（未读消息常驻显示）
        if (!isSent) ...[
          SecurityIcon(status: securityStatus, size: 14),
          const SizedBox(width: 8),
        ],
        Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.7,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isSent
                ? AppTheme.black
                : AppTheme.surface,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(6),
              topRight: const Radius.circular(6),
              bottomLeft: isSent
                  ? const Radius.circular(6)
                  : const Radius.circular(0),
              bottomRight: isSent
                  ? const Radius.circular(0)
                  : const Radius.circular(6),
            ),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: isSent ? AppTheme.white : AppTheme.black,
              fontSize: 14,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
        if (isSent) ...[
          const SizedBox(width: 4),
          // 已读状态（无红点，用简单图标）
          Icon(
            isRead ? Icons.done_all : Icons.done,
            size: 12,
            color: AppTheme.midGray,
          ),
        ],
      ],
    );
  }
}

/// 聊天界面
class ChatScreen extends StatefulWidget {
  final String contactName;

  const ChatScreen({super.key, required this.contactName});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messages = <Map<String, dynamic>>[];
  final _textController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            // 安全状态图标（常驻显示）
            SecurityIcon(status: SecurityStatus.unverified, size: 14),
            const SizedBox(width: 8),
            Text(
              widget.contactName,
              style: const TextStyle(
                color: AppTheme.black,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        centerTitle: false,
        elevation: 0,
        backgroundColor: AppTheme.white,
        leading: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.arrow_back, size: 20),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.call, size: 20),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.videocam, size: 20),
          ),
        ],
      ),
      body: Column(
        children: [
          // 聊天内容区域
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ChatBubble(
                    text: msg['text'] as String,
                    isSent: msg['isSent'] as bool,
                    isRead: msg['isRead'] as bool,
                    burnAfterRead: msg['burnAfterRead'] as bool,
                    securityStatus: msg['securityStatus'] as SecurityStatus,
                  ),
                );
              },
            ),
          ),
          // 底部输入区域
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
              color: AppTheme.surface,
              border: Border(
                top: BorderSide(color: AppTheme.lightGray, width: 1),
              ),
            ),
            child: Row(
              children: [
                // 安全状态标识
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    securityStatusText(),
                    style: const TextStyle(
                      color: AppTheme.midGray,
                      fontSize: 11,
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: InputDecoration(
                      hintText: '输入消息...',
                      hintStyle: const TextStyle(
                        color: AppTheme.midGray,
                        fontSize: 14,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: AppTheme.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                    ),
                    maxLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                // 附件按钮（极简线条）
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppTheme.lightGray,
                      width: 1,
                    ),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.attach_file, size: 18),
                    onPressed: () {},
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(width: 8),
                // 发送按钮
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.black,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.send, size: 18),
                    onPressed: _sendMessage,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String securityStatusText() {
    switch (SecurityStatus.unverified) {
      case SecurityStatus.verified:
        return '已验证';
      case SecurityStatus.unverified:
        return '未验证';
    }
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.add({
        'text': text,
        'isSent': true,
        'isRead': false,
        'burnAfterRead': false,
        'securityStatus': SecurityStatus.unverified,
      });
    });
    _textController.clear();
  }
}
