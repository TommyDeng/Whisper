/// 耳语 Whisper - 聊天界面
///
/// 1:1 E2EE 文字聊天。黑白/单色细线条风格，安全状态常驻显示。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../contact/contact.dart';
import '../messaging/message_codec.dart';
import '../messaging/messaging_service.dart';
import '../relay/session_client.dart';
import 'app_theme.dart';

/// 聊天气泡
class ChatBubble extends StatelessWidget {
  final String text;
  final bool isSent;

  /// 自己发出的消息的状态；收到的消息为 null。
  final OutgoingStatus? status;
  final SecurityStatus securityStatus;

  /// 阅后即焚的消息：对方读过之后两边都会删除。
  final bool burn;

  const ChatBubble({
    super.key,
    required this.text,
    required this.isSent,
    this.status,
    this.securityStatus = SecurityStatus.unverified,
    this.burn = false,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, tooltip, color) = switch (status) {
      OutgoingStatus.sending => (Icons.schedule, '发送中', AppTheme.midGray),
      OutgoingStatus.sent => (Icons.done, '已发送', AppTheme.midGray),
      OutgoingStatus.delivered => (Icons.done_all, '已送达', AppTheme.midGray),
      OutgoingStatus.failed => (Icons.error_outline, '发送失败', AppTheme.red),
      null => (Icons.done, '', AppTheme.midGray),
    };
    const burnMark = Tooltip(
      message: '阅后即焚：读过之后两边都会删除',
      child: Icon(Icons.local_fire_department_outlined, size: 14, color: AppTheme.midGray),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: isSent ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (!isSent) ...[
          SecurityIcon(status: securityStatus, size: 14),
          const SizedBox(width: 8),
        ],
        if (isSent && burn) ...[burnMark, const SizedBox(width: 4)],
        Flexible(
          child: Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isSent ? AppTheme.black : AppTheme.surface,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(6),
                topRight: const Radius.circular(6),
                bottomLeft: Radius.circular(isSent ? 6 : 0),
                bottomRight: Radius.circular(isSent ? 0 : 6),
              ),
            ),
            child: SelectableText(
              text,
              style: TextStyle(
                color: isSent ? AppTheme.white : AppTheme.black,
                fontSize: 14,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ),
        if (!isSent && burn) ...[const SizedBox(width: 4), burnMark],
        if (isSent && status != null) ...[
          const SizedBox(width: 4),
          Tooltip(message: tooltip, child: Icon(icon, size: 12, color: color)),
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
  final _messaging = AppServices.instance.messaging;
  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  StreamSubscription<String>? _subscription;
  List<ChatMessage> _messages = [];
  late bool _verified = widget.contact.isVerified;
  late bool _burn = widget.contact.burnAfterRead;
  bool _isLoading = true;
  bool _reloading = false;
  bool _reloadAgain = false;

  String get _sessionId => widget.contact.sessionId;

  SecurityStatus get _security => _verified ? SecurityStatus.verified : SecurityStatus.unverified;

  @override
  void initState() {
    super.initState();
    _subscription = _messaging.updates.listen((sessionId) {
      if (sessionId == _sessionId) unawaited(_loadMessages());
    });
    unawaited(_loadMessages());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    // 离开聊天时，读过的阅后即焚消息从本机删除
    unawaited(_messaging.purgeBurned(sessionId: _sessionId).then<void>((_) {}, onError: (_) {}));
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 重新读取消息。更新来得很密时合并成一次接一次，不并发读库。
  Future<void> _loadMessages() async {
    if (_reloading) {
      _reloadAgain = true;
      return;
    }
    _reloading = true;
    try {
      do {
        _reloadAgain = false;
        List<ChatMessage> messages;
        try {
          messages = await _messaging.messages(widget.contact);
        } catch (_) {
          messages = _messages;
        }
        if (!mounted) return;
        setState(() {
          _messages = messages;
          _isLoading = false;
        });
        // 消息已经显示在屏幕上，算读过；阅后即焚的会通知对方删除
        if (messages.any((message) => !message.isSent)) {
          try {
            await _messaging.markRead(widget.contact);
          } catch (_) {
            // 标记失败不影响显示，下次刷新再试
          }
          if (!mounted) return;
        }
      } while (_reloadAgain);
    } finally {
      _reloading = false;
    }
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    _focusNode.requestFocus();
    try {
      await _messaging.sendText(widget.contact, text, burn: _burn);
    } on ArgumentError {
      _textController.text = text;
      _toast('消息太长了（上限约 ${MessageCodec.maxTextBytes ~/ 1024} KB），请分几条发。');
    } catch (_) {
      _textController.text = text;
      _toast('发送失败，请稍后再试。');
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), backgroundColor: AppTheme.red),
    );
  }

  Future<void> _showSafetyCode() async {
    final verified = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('安全码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('通过电话或当面，和对方核对这串安全码。两边一致，说明没有人冒充对方。'),
            const SizedBox(height: 12),
            SelectableText(
              widget.contact.safetyCode,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
          if (_verified)
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消已验证标记'),
            )
          else
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('已核对一致'),
            ),
        ],
      ),
    );
    if (verified == null) return;
    await ContactStore.updateContactVerification(widget.contact.deviceId, verified);
    if (mounted) setState(() => _verified = verified);
  }

  Future<void> _toggleBurn() async {
    final enabled = !_burn;
    await ContactStore.updateContactBurnAfterRead(widget.contact.deviceId, enabled);
    if (!mounted) return;
    setState(() => _burn = enabled);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled ? '阅后即焚已开启：之后你发出的消息，对方读过后两边都会删除。' : '阅后即焚已关闭。已经发出的阅后即焚消息不受影响。',
        ),
      ),
    );
  }

  String get _linkText {
    switch (_messaging.linkState(_sessionId)) {
      case SessionLinkState.connected:
        return _messaging.peerOnline(_sessionId) ? '对方在线' : '对方不在线，消息会在 7 天内等对方上线';
      case SessionLinkState.connecting:
        return '正在连接…';
      case SessionLinkState.disconnected:
        return '未连接，消息会在连上后发出';
    }
  }

  Future<void> _startCall() async {
    try {
      await AppServices.instance.calls.start(widget.contact);
    } on StateError {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已有一通通话在进行')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _showSafetyCode,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SecurityIcon(status: _security, size: 14),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.contactName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTheme.black, fontSize: 18, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
        centerTitle: false,
        elevation: 0,
        backgroundColor: AppTheme.white,
        actions: [
          IconButton(
            tooltip: '语音通话',
            icon: const Icon(Icons.call_outlined, color: AppTheme.black),
            onPressed: () => unawaited(_startCall()),
          ),
          IconButton(
            tooltip: _burn ? '关闭阅后即焚' : '开启阅后即焚',
            icon: Icon(
              _burn ? Icons.local_fire_department : Icons.local_fire_department_outlined,
              color: _burn ? AppTheme.black : AppTheme.midGray,
            ),
            onPressed: () => unawaited(_toggleBurn()),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 6),
            child: Text(_linkText, style: const TextStyle(color: AppTheme.midGray, fontSize: 11)),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessages()),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
              color: AppTheme.surface,
              border: Border(top: BorderSide(color: AppTheme.lightGray, width: 1)),
            ),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    '${_verified ? '已验证' : '未验证'}${_burn ? ' · 阅后即焚' : ''}',
                    style: const TextStyle(color: AppTheme.midGray, fontSize: 11),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _textController,
                    focusNode: _focusNode,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: '输入消息...',
                      hintStyle: const TextStyle(color: AppTheme.midGray, fontSize: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: AppTheme.white,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    maxLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => unawaited(_sendMessage()),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: const BoxDecoration(color: AppTheme.black, shape: BoxShape.circle),
                  child: IconButton(
                    tooltip: '发送',
                    icon: const Icon(Icons.send, size: 18, color: AppTheme.white),
                    onPressed: () => unawaited(_sendMessage()),
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
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

  Widget _buildMessages() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_messages.isEmpty) {
      return const Center(
        child: Text('暂无消息', style: TextStyle(color: AppTheme.darkGray, fontSize: 16)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      reverse: true,
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[_messages.length - 1 - index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ChatBubble(
            text: message.text ?? '（这条消息无法解密）',
            isSent: message.isSent,
            status: message.status,
            securityStatus: _security,
            burn: message.burn,
          ),
        );
      },
    );
  }
}
