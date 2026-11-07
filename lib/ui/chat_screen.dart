/// 耳语 Whisper - 聊天界面
///
/// 主要界面之一：1:1 E2EE 文字聊天
/// 黑白/单色细线条风格，安全状态常驻显示

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:cryptography/cryptography.dart';

import '../contact/contact.dart';
import '../e2ee/crypto.dart';
import '../e2ee/message.dart';
import '../identity/identity.dart';
import '../identity/identity_store.dart';
import '../storage/local_db.dart';
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
  final Contact contact;

  const ChatScreen({
    super.key,
    required this.contactName,
    required this.contact,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final List<StoredMessage> _messages = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    final messages = await LocalDatabase.getSessionMessages(widget.contact.deviceId);
    _messages.clear();
    _messages.addAll(messages);
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    _textController.clear();

    try {
      final identityManager = IdentityManager(store: IdentityStore());
      final identity = await identityManager.identity;
      final x25519 = X25519();
      final localKeyPair = await x25519.newKeyPairFromSeed(identity.x25519PrivateKey);
      final sessionKey = await SessionCrypto.deriveSessionKey(
        localKeyPair: localKeyPair,
        remotePublicKey: SimplePublicKey(
          base64Url.decode(widget.contact.x25519PublicKeyBase64),
          type: KeyPairType.x25519,
        ),
      );

      final encrypted = await SessionCrypto.encrypt(
        secretKey: sessionKey,
        sessionId: widget.contact.deviceId,
        sequenceNumber: _messages.length,
        plaintext: text,
      );

      final ciphertextJson = jsonEncode(encrypted.toJson());

      final stored = StoredMessage(
        msgId: DateTime.now().millisecondsSinceEpoch.toString(),
        sessionId: widget.contact.deviceId,
        senderPublicKey: identity.x25519PublicKeyBase64,
        ciphertext: ciphertextJson,
        sequenceNumber: _messages.length,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        direction: 'sent',
        delivered: true,
        read: true,
        burnAfterRead: false,
      );

      await LocalDatabase.insertMessage(stored);

      setState(() {
        _messages.insert(0, stored);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发送失败：$e'),
            backgroundColor: AppTheme.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            SecurityIcon(status: widget.contact.isVerified ? SecurityStatus.verified : SecurityStatus.unverified, size: 14),
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
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      '暂无消息',
                      style: TextStyle(
                        color: AppTheme.darkGray,
                        fontSize: 16,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    reverse: true,
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[_messages.length - 1 - index];
                      final isSent = msg.direction == 'sent';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ChatBubble(
                          text: isSent ? '[E2EE 已加密]' : '[E2EE 已加密]',
                          isSent: isSent,
                          isRead: msg.read,
                          burnAfterRead: msg.burnAfterRead,
                          securityStatus: widget.contact.isVerified ? SecurityStatus.verified : SecurityStatus.unverified,
                        ),
                      );
                    },
                  ),
          ),
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
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    widget.contact.isVerified ? '已验证' : '未验证',
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
}
