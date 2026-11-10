/// 耳语 Whisper - 联系人列表界面
///
/// 黑白/单色细线条风格，无头像墙、无红点轰炸。
/// 安全状态（已验证/未验证）用简单线条图标常驻显示。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../contact/contact.dart';
import '../pairing/pairing_manager.dart';
import '../pairing/pairing_page.dart';
import 'app_theme.dart';
import 'chat_screen.dart';

/// 联系人条目
class ContactItem extends StatelessWidget {
  final Contact contact;
  final bool online;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const ContactItem({
    super.key,
    required this.contact,
    required this.onTap,
    required this.onDelete,
    this.online = false,
  });

  String get _subtitle {
    if (!contact.hasSession) return '旧版联系人，需要重新配对';
    final key = contact.x25519PublicKeyBase64;
    final fingerprint = key.length > 8 ? key.substring(0, 8) : key;
    return online ? '在线 · $fingerprint' : fingerprint;
  }

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
            SecurityIcon(
              status: contact.isVerified ? SecurityStatus.verified : SecurityStatus.unverified,
              size: 14,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.name,
                    style: const TextStyle(
                      color: AppTheme.black,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subtitle,
                    style: const TextStyle(
                      color: AppTheme.darkGray,
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            InkWell(
              onTap: onDelete,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.close, size: 16, color: AppTheme.midGray),
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
  final _services = AppServices.instance;
  final List<StreamSubscription<void>> _subscriptions = [];
  List<Contact> _contacts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _subscriptions.addAll([
      // 新消息会改变排序，在线状态会改变副标题
      _services.messaging.updates.listen((_) => unawaited(_loadContacts())),
      _services.pairing.changes.listen((_) {
        if (mounted) setState(() {});
      }),
      _services.pairing.notices.listen((notice) {
        if (notice.kind == PairingNoticeKind.contactAdded) unawaited(_loadContacts());
      }),
    ]);
    unawaited(_loadContacts());
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  Future<void> _loadContacts() async {
    List<Contact> contacts;
    try {
      contacts = await ContactStore.getAllContacts();
    } catch (_) {
      contacts = _contacts;
    }
    if (!mounted) return;
    setState(() {
      _contacts = contacts;
      _isLoading = false;
    });
  }

  Future<void> _openPairing() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => const PairingPage()),
    );
    await _loadContacts();
  }

  Future<void> _openChat(Contact contact) async {
    if (!contact.hasSession) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这位联系人是旧版本添加的，请删除后重新配对。')),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => ChatScreen(contactName: contact.name, contact: contact)),
    );
    await _loadContacts();
  }

  Future<void> _deleteContact(Contact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${contact.name}？'),
        content: const Text('本机上与这位联系人的聊天记录会一并删除，且无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _services.removeContact(contact);
    await _loadContacts();
  }

  @override
  Widget build(BuildContext context) {
    final pendingRequests = _services.pairing.incomingRequests.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '联系人',
          style: TextStyle(color: AppTheme.black, fontSize: 18, fontWeight: FontWeight.w500),
        ),
        centerTitle: false,
        elevation: 0,
        backgroundColor: AppTheme.white,
        actions: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: IconButton(
              tooltip: '添加联系人 / 我的邀请码',
              icon: const Icon(Icons.qr_code, size: 20),
              onPressed: _openPairing,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (pendingRequests > 0)
            InkWell(
              onTap: _openPairing,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(
                  color: AppTheme.surface,
                  border: Border(bottom: BorderSide(color: AppTheme.lightGray, width: 1)),
                ),
                child: Text(
                  '有 $pendingRequests 个配对请求等你处理 ›',
                  style: const TextStyle(color: AppTheme.black, fontSize: 13),
                ),
              ),
            ),
          Expanded(child: _buildList()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openPairing,
        child: const Icon(Icons.person_add, size: 20),
      ),
    );
  }

  Widget _buildList() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.black),
      );
    }
    if (_contacts.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_outline, size: 48, color: AppTheme.midGray),
            SizedBox(height: 12),
            Text('暂无联系人', style: TextStyle(color: AppTheme.darkGray, fontSize: 16)),
            SizedBox(height: 8),
            Text('通过扫码或邀请码添加亲友', style: TextStyle(color: AppTheme.midGray, fontSize: 12)),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: _contacts.length,
      itemBuilder: (context, index) {
        final contact = _contacts[index];
        return ContactItem(
          contact: contact,
          online: _services.messaging.peerOnline(contact.sessionId),
          onTap: () => unawaited(_openChat(contact)),
          onDelete: () => unawaited(_deleteContact(contact)),
        );
      },
    );
  }
}
