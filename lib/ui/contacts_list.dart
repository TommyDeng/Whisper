/// 耳语 Whisper - 联系人列表界面
///
/// 主要界面之一：联系人列表
/// 黑白/单色细线条风格，无头像墙、无红点轰炸
/// 安全状态（已验证/未验证）用简单线条图标常驻显示

import 'dart:convert';

import 'package:flutter/material.dart';

import '../contact/contact.dart';
import '../contact/contact_model.dart';
import '../contact/contact_store.dart';
import '../identity/identity.dart';
import '../identity/identity_store.dart';
import '../pairing/invitation_code.dart';
import '../ui/chat_screen.dart';
import 'app_theme.dart';

/// 联系人条目
class ContactItem extends StatelessWidget {
  final Contact contact;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const ContactItem({
    super.key,
    required this.contact,
    required this.onTap,
    required this.onDelete,
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
            SecurityIcon(status: contact.isVerified ? SecurityStatus.verified : SecurityStatus.unverified, size: 14),
            const SizedBox(width: 12),
            // 联系人名称（无头像）
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
                    contact.deviceId,
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
            // 删除按钮
            InkWell(
              onTap: onDelete,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(
                  Icons.close,
                  size: 16,
                  color: AppTheme.midGray,
                ),
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
  List<Contact> _contacts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    final contacts = await ContactStore.getAllContacts();
    setState(() {
      _contacts = contacts;
      _isLoading = false;
    });
  }

  Future<void> _addContact() async {
    final result = await showDialog<Contact>(
      context: context,
      builder: (context) => const _AddContactDialog(),
    );
    if (result != null) {
      await ContactStore.upsertContact(result);
      setState(() {
        final updated = [..._contacts, result];
        updated.sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
        _contacts = updated;
      });
    }
  }

  Future<void> _deleteContact(String deviceId) async {
    await ContactStore.deleteContact(deviceId);
    setState(() {
      _contacts.removeWhere((c) => c.deviceId == deviceId);
    });
  }

  Future<void> _showMyInvitationCode() async {
    try {
      final identityManager = IdentityManager(store: IdentityStore());
      final identity = await identityManager.identity;
      final code = InvitationCode.create(identity.x25519PublicKey);

      if (!mounted) return;
      await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('我的邀请码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('把这个码发给对方，对方输入即可添加你为联系人：'),
              const SizedBox(height: 12),
              SelectableText(
                code.encode(),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '有效期：24 小时，一次性',
                style: const TextStyle(
                  color: AppTheme.midGray,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('生成失败：$e'),
            backgroundColor: AppTheme.red,
          ),
        );
      }
    }
  }

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
            child: IconButton(
              icon: const Icon(Icons.person_add, size: 20),
              onPressed: _addContact,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: IconButton(
              icon: const Icon(Icons.qr_code, size: 20),
              onPressed: _showMyInvitationCode,
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppTheme.black,
              ),
            )
          : _contacts.isEmpty
              ? Center(
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
                )
              : ListView.builder(
                  itemCount: _contacts.length,
                  itemBuilder: (context, index) {
                    final contact = _contacts[index];
                    return ContactItem(
                      contact: contact,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => ChatScreen(
                              contactName: contact.name,
                              contact: contact,
                            ),
                          ),
                        );
                      },
                      onDelete: () => _deleteContact(contact.deviceId),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addContact,
        child: const Icon(Icons.person_add, size: 20),
      ),
    );
  }
}

/// 添加联系人对话框（输入邀请码）
class _AddContactDialog extends StatefulWidget {
  const _AddContactDialog();

  @override
  State<_AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<_AddContactDialog> {
  final _codeController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _addContact() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final invitation = InvitationCode.decode(code);
      if (invitation == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('邀请码格式无效'),
              backgroundColor: AppTheme.red,
            ),
          );
        }
        return;
      }

      if (invitation.isExpired) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('邀请码已过期'),
              backgroundColor: AppTheme.red,
            ),
          );
        }
        return;
      }

      final identityManager = IdentityManager(store: IdentityStore());
      final identity = await identityManager.identity;

      final contact = Contact(
        deviceId: base64Url.encode(invitation.publicKey).substring(0, 12),
        name: '新联系人',
        x25519PublicKeyBase64: base64Url.encode(invitation.publicKey),
        ed25519PublicKeyBase64: '',
        safetyCode: SafetyCode.compute(
          identity.x25519PublicKeyBase64,
          base64Url.encode(invitation.publicKey),
        ),
        isVerified: false,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        lastMessageTime: DateTime.now().millisecondsSinceEpoch,
      );

      if (mounted) {
        Navigator.of(context).pop(contact);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('添加失败：$e'),
            backgroundColor: AppTheme.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加联系人'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('粘贴对方的邀请码：'),
          const SizedBox(height: 12),
          TextField(
            controller: _codeController,
            decoration: const InputDecoration(
              hintText: '邀请码（Base32）',
              border: OutlineInputBorder(),
            ),
            maxLines: 1,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _isLoading ? null : _addContact,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('添加'),
        ),
      ],
    );
  }
}
