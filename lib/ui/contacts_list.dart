/// 耳语 Whisper - 联系人列表界面
///
/// 宽窗口左右分栏：左边联系人，右边聊天；窄窗口退回单栏。
/// 安全状态（已验证/未验证）常驻显示。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../contact/contact.dart';
import '../desktop/autostart.dart';
import '../storage/local_db.dart';
import '../update/app_update.dart';
import '../pairing/pairing_manager.dart';
import '../pairing/pairing_page.dart';
import 'about.dart';
import 'app_theme.dart';
import 'chat_screen.dart';

/// 联系人条目
class ContactItem extends StatefulWidget {
  final Contact contact;
  final bool online;
  final int unread;

  /// 分栏时右边正在看的就是这位联系人。
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const ContactItem({
    super.key,
    required this.contact,
    required this.onTap,
    required this.onDelete,
    this.online = false,
    this.unread = 0,
    this.selected = false,
  });

  @override
  State<ContactItem> createState() => _ContactItemState();
}

class _ContactItemState extends State<ContactItem> {
  var _hovered = false;

  Contact get _contact => widget.contact;

  /// 公钥的前 4 个字节，写成十六进制，前面带 `0x`。只是帮人认出是哪一把钥匙，不是安全码。
  String get _fingerprint {
    final key = _contact.x25519PublicKeyBase64;
    try {
      final bytes = base64.decode(base64.normalize(key));
      if (bytes.length >= 4) {
        final hex = bytes
            .take(4)
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        return '0x$hex';
      }
    } on FormatException {
      // 不是合法的 Base64（旧数据），退回原样显示。
    }
    return key.length > 8 ? key.substring(0, 8) : key;
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final rowColor = selected
        ? AppTheme.accentSoft
        : (_hovered ? AppTheme.hover : AppTheme.panel);
    const subtitleStyle = TextStyle(color: AppTheme.text2, fontSize: 12);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          key: ValueKey('contact-row-${_contact.deviceId}'),
          height: 60,
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
          padding: const EdgeInsets.only(left: 8, right: 4),
          decoration: BoxDecoration(
            color: rowColor,
            borderRadius: AppTheme.corners,
            border: Border(
              left: BorderSide(
                color: selected ? AppTheme.accent : rowColor,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              ContactMark(
                name: _contact.name,
                online: widget.online,
                ring: rowColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _contact.name,
                            style: TextStyle(
                              color: selected
                                  ? AppTheme.textBright
                                  : AppTheme.text,
                              fontSize: 15,
                              fontWeight: widget.unread > 0
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Tooltip(
                          message: _contact.isVerified ? '已验证安全码' : '还没验证安全码',
                          child: SecurityIcon(
                            status: _contact.isVerified
                                ? SecurityStatus.verified
                                : SecurityStatus.unverified,
                            size: 13,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    if (!_contact.hasSession)
                      const Text(
                        '旧版联系人，需要重新配对',
                        style: subtitleStyle,
                        overflow: TextOverflow.ellipsis,
                      )
                    else
                      Text.rich(
                        TextSpan(
                          children: [
                            if (widget.online)
                              const TextSpan(
                                text: '在线',
                                style: TextStyle(color: AppTheme.accent),
                              )
                            else
                              const TextSpan(text: '离线'),
                            TextSpan(
                              text: '  $_fingerprint',
                              style: AppTheme.mono(
                                color: selected
                                    ? AppTheme.text2
                                    : AppTheme.text3,
                              ),
                            ),
                          ],
                        ),
                        style: subtitleStyle,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (widget.unread > 0) ...[
                _UnreadBadge(count: widget.unread),
                const SizedBox(width: 4),
              ],
              // 删除按钮平时收着，鼠标移到这一行才出现；位置一直占着，行内不会跳。
              Visibility(
                visible: _hovered,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: TermIconButton(
                  tooltip: '删除联系人',
                  size: 30,
                  iconSize: 16,
                  icon: Icons.close,
                  hoverColor: AppTheme.alert,
                  onPressed: widget.onDelete,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 联系人列表页面
class ContactsListScreen extends StatefulWidget {
  const ContactsListScreen({
    super.key,
    this.loadContacts,
    this.loadUnread,
    this.isOnline,
    this.chatBuilder,
    this.removeContact,
  });

  /// 下面几个参数只给测试用：正式界面读本地库、走 [AppServices]。
  final Future<List<Contact>> Function()? loadContacts;
  final Future<Map<String, int>> Function()? loadUnread;
  final bool Function(Contact contact)? isOnline;

  /// 造聊天界面；[onBack] 只在单栏时不为 null。
  final Widget Function(Contact contact, VoidCallback? onBack)? chatBuilder;
  final Future<void> Function(Contact contact)? removeContact;

  @override
  State<ContactsListScreen> createState() => _ContactsListScreenState();
}

class _ContactsListScreenState extends State<ContactsListScreen> {
  final _services = AppServices.instance;
  final List<StreamSubscription<void>> _subscriptions = [];
  List<Contact> _contacts = [];
  Map<String, int> _unread = {};
  bool _isLoading = true;

  /// 正在看的联系人（按设备 id 记）。分栏时显示在右边，单栏时整页显示。
  String? _selectedId;

  Contact? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final contact in _contacts) {
      if (contact.deviceId == id) return contact;
    }
    return null;
  }

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
        if (notice.kind == PairingNoticeKind.contactAdded) {
          unawaited(_loadContacts());
        }
      }),
      _services.files.updates.listen((_) => unawaited(_loadContacts())),
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
    Map<String, int> unread;
    try {
      contacts = await (widget.loadContacts ?? ContactStore.getAllContacts)();
    } catch (_) {
      contacts = _contacts;
    }
    try {
      unread = await (widget.loadUnread ?? LocalDatabase.unreadCounts)();
    } catch (_) {
      unread = _unread;
    }
    if (!mounted) return;
    setState(() {
      _contacts = contacts;
      _unread = unread;
      _isLoading = false;
    });
  }

  int _unreadFor(Contact contact) {
    var count = _unread[contact.sessionId] ?? 0;
    try {
      count += _services.files
          .incoming(contact.sessionId)
          .where((item) => item.needsAccept)
          .length;
    } catch (_) {}
    return count;
  }

  Future<void> _openPairing() async {
    await showPairingDialog(context);
    await _loadContacts();
  }

  Future<void> _openChat(Contact contact) async {
    if (!contact.hasSession) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这位联系人是旧版本添加的，请删除后重新配对。')));
      return;
    }
    // 不跳页：分栏时换右边的内容，单栏时在原地换成聊天。
    setState(() => _selectedId = contact.deviceId);
  }

  void _closeChat() {
    setState(() => _selectedId = null);
    unawaited(_loadContacts());
  }

  Future<void> _deleteContact(Contact contact) async {
    final confirmed = await showTermDialog<bool>(
      context: context,
      builder: (context) => TermDialog(
        title: '删除 ${contact.name}？',
        tag: 'DANGER_',
        width: 400,
        content: const Text('本机上与这位联系人的聊天记录会一并删除，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: AppTheme.dangerFilledButton,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // 删的是正在看的人：先把右边收回空状态，聊天界面不再碰已删除的会话。
    if (_selectedId == contact.deviceId && mounted) {
      setState(() => _selectedId = null);
    }
    await (widget.removeContact ?? _services.removeContact)(contact);
    await _loadContacts();
  }

  Future<void> _clearAllData() async {
    final confirmed = await showTermDialog<bool>(
      context: context,
      builder: (context) => TermDialog(
        title: '清除全部数据？',
        tag: 'DANGER_',
        width: 400,
        content: const Text(
          '本机上的聊天记录、联系人和你的身份都会被删除，且无法恢复。\n\n'
          '之后你会得到一个新的身份，需要和每位联系人重新配对。对方设备上的记录不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: AppTheme.dangerFilledButton,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('全部清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    String message = '已清除全部数据';
    if (mounted) setState(() => _selectedId = null);
    try {
      await _services.clearAllData();
    } catch (_) {
      message = '没能清除完，请重启应用后再试一次';
    }
    await _loadContacts();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 「更多」菜单：贴着按钮下沿弹出。
  Future<void> _openMoreMenu(BuildContext buttonContext) async {
    final button = buttonContext.findRenderObject() as RenderBox;
    final overlay =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox;
    final topLeft = button.localToGlobal(
      Offset(0, button.size.height + 4),
      ancestor: overlay,
    );
    final chosen = await showMenu<String>(
      context: buttonContext,
      constraints: const BoxConstraints(minWidth: 180),
      position: RelativeRect.fromRect(
        topLeft & button.size,
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: 'clear',
          child: Text('清除全部数据…', style: TextStyle(color: AppTheme.alert)),
        ),
      ],
    );
    if (chosen == 'clear') await _clearAllData();
  }

  /// 窗口至少这么宽才分栏；再窄就退回单栏（先列表，点进去是整页聊天）。
  static const double splitMinWidth = 720;
  static const double _sidebarWidth = 300;

  /// 边栏顶部的图标按钮：比默认的 48 小，三个才放得下。
  static const double _headerButton = 34;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final selected = _selected;
        if (constraints.maxWidth < splitMinWidth) {
          return PaneSwitcher(
            child: selected == null
                ? KeyedSubtree(
                    key: const ValueKey('contacts'),
                    child: Scaffold(body: _buildSidebar(null)),
                  )
                : KeyedSubtree(
                    key: ValueKey('chat-${selected.deviceId}'),
                    child: _buildChat(selected, onBack: _closeChat),
                  ),
          );
        }
        return Scaffold(
          body: Row(
            children: [
              SizedBox(width: _sidebarWidth, child: _buildSidebar(selected)),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(
                child: PaneSwitcher(
                  child: selected == null
                      ? const _NoChatSelected(key: ValueKey('empty'))
                      : KeyedSubtree(
                          key: ValueKey('chat-${selected.deviceId}'),
                          child: _buildChat(selected),
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildChat(Contact contact, {VoidCallback? onBack}) {
    final builder = widget.chatBuilder;
    if (builder != null) return builder(contact, onBack);
    return ChatScreen(
      // 换人就换一个新的聊天界面：没发出去的字不带到别人那里。
      key: ValueKey('chat-${contact.deviceId}'),
      contactName: contact.name,
      contact: contact,
      onBack: onBack,
      onRead: () => unawaited(_loadContacts()),
    );
  }

  Widget _buildSidebar(Contact? selected) {
    final pendingRequests = _services.pairing.incomingRequests.length;
    return ColoredBox(
      color: AppTheme.panel,
      child: Column(
        children: [
          SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.only(left: 20, right: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Flexible(
                    child: Text(
                      '耳语',
                      overflow: TextOverflow.clip,
                      softWrap: false,
                      style: TextStyle(
                        color: AppTheme.text,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: TagLabel('WHISPER_'),
                  ),
                  const Spacer(),
                  TermIconButton(
                    tooltip: '添加联系人 / 我的邀请码',
                    size: _headerButton,
                    icon: Icons.person_add_outlined,
                    onPressed: _openPairing,
                  ),
                  TermIconButton(
                    tooltip: '关于',
                    size: _headerButton,
                    icon: Icons.info_outline,
                    onPressed: () => unawaited(
                      showAboutWhisperDialog(
                        context,
                        autostart: Autostart.forPlatform(),
                        updater: GithubAppUpdater.forPlatform(),
                        onQuitForUpdate: _services.window.quit,
                      ),
                    ),
                  ),
                  Builder(
                    builder: (buttonContext) => TermIconButton(
                      tooltip: '更多',
                      size: _headerButton,
                      icon: Icons.more_horiz,
                      onPressed: () => unawaited(_openMoreMenu(buttonContext)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (pendingRequests > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: InkWell(
                onTap: _openPairing,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: const BoxDecoration(
                    color: AppTheme.accentSoft,
                    borderRadius: AppTheme.corners,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.person_add_outlined,
                        size: 16,
                        color: AppTheme.accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '有 $pendingRequests 个配对请求等你处理',
                          style: const TextStyle(
                            color: AppTheme.accent,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: AppTheme.accent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(child: _buildList(selected)),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
            child: Row(
              children: [
                const Icon(
                  Icons.shield_outlined,
                  size: 14,
                  color: AppTheme.text3,
                ),
                const SizedBox(width: 6),
                Text(
                  'E2EE · X25519',
                  style: AppTheme.mono(color: AppTheme.text3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(Contact? selected) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_contacts.isEmpty) {
      return Center(
        child: _EmptyState(
          icon: Icons.person_add_outlined,
          title: '暂无联系人',
          subtitle: '用邀请码添加亲友',
          action: FilledButton.icon(
            onPressed: _openPairing,
            icon: const Icon(Icons.person_add_outlined),
            label: const Text('添加联系人'),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _contacts.length,
      itemBuilder: (context, index) {
        final contact = _contacts[index];
        return ContactItem(
          contact: contact,
          online:
              widget.isOnline?.call(contact) ??
              _services.messaging.peerOnline(contact.sessionId),
          unread: _unreadFor(contact),
          selected: selected?.deviceId == contact.deviceId,
          onTap: () => unawaited(_openChat(contact)),
          onDelete: () => unawaited(_deleteContact(contact)),
        );
      },
    );
  }
}

/// 分栏时还没选联系人，右边显示的内容。
class _NoChatSelected extends StatelessWidget {
  const _NoChatSelected({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppTheme.bg,
      child: Center(
        child: _EmptyState(
          icon: Icons.chat_bubble_outline,
          title: '选一个联系人开始聊天',
          subtitle: '消息端到端加密，服务器看不到内容',
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppTheme.field,
              borderRadius: AppTheme.corners,
              border: Border.all(color: AppTheme.border),
            ),
            child: Icon(icon, size: 26, color: AppTheme.accent),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTheme.text,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.text2, fontSize: 12.5),
          ),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: AppTheme.alert,
        borderRadius: AppTheme.corners,
      ),
      // 不用 Container 的 alignment：它会把角标撑满整行的高度。
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          label,
          style: const TextStyle(
            color: AppTheme.onAlert,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
