/// 配对对话框：自己的邀请码（二维码 + 文本）、输入对方的邀请码、处理收到的配对请求。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_services.dart';
import '../storage/settings_store.dart';
import '../ui/app_theme.dart';
import 'invitation_code.dart';
import 'pairing_flow.dart';
import 'pairing_manager.dart';

/// 弹出「添加联系人」对话框，用法和「关于」一样：点关闭或点对话框外面收起。
Future<void> showPairingDialog(
  BuildContext context, {
  PairingManager? manager,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => PairingPage(manager: manager),
  );
}

class PairingPage extends StatefulWidget {
  const PairingPage({super.key, this.manager});

  /// 测试时注入；默认用应用级的那个。
  final PairingManager? manager;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  late final PairingManager _manager =
      widget.manager ?? AppServices.instance.pairing;
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final List<StreamSubscription<void>> _subscriptions = [];

  InvitationCode? _invitation;
  String? _invitationError;
  String? _joinError;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _subscriptions.add(
      _manager.changes.listen((_) {
        if (!mounted) return;
        // 手上的邀请被用掉或过期后，换一个新的
        if (_invitation != null &&
            _manager.openInvitation?.inviteId != _invitation!.inviteId) {
          final stillPending = _manager.incomingRequests.any(
            (r) => r.inviteId == _invitation!.inviteId,
          );
          if (!stillPending) unawaited(_loadInvitation());
        }
        setState(() {});
      }),
    );
    _subscriptions.add(_manager.notices.listen(_onNotice));
    unawaited(_loadName());
    unawaited(_loadInvitation());
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadName() async {
    try {
      final name = await SettingsStore.get(SettingsStore.displayName);
      if (mounted && name != null) _nameController.text = name;
    } catch (_) {
      // 读不到就留空
    }
  }

  Future<void> _saveName() async {
    try {
      await SettingsStore.set(
        SettingsStore.displayName,
        _nameController.text.trim(),
      );
    } catch (_) {
      _toast('名字没能保存');
    }
  }

  Future<void> _loadInvitation() async {
    try {
      final invitation = await _manager.ensureInvitation();
      if (!mounted) return;
      setState(() {
        _invitation = invitation;
        _invitationError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _invitationError = '邀请码生成失败');
    }
  }

  Future<void> _join() async {
    final code = _codeController.text.trim();
    if (code.isEmpty || _joining) return;
    setState(() {
      _joining = true;
      _joinError = null;
    });
    await _saveName();
    JoinError? error;
    String? unexpected;
    try {
      error = await _manager.join(code);
    } catch (_) {
      unexpected = '发起配对失败';
    }
    if (!mounted) return;
    setState(() {
      _joining = false;
      _joinError =
          unexpected ??
          switch (error) {
            null => null,
            JoinError.invalidCode => '邀请码格式不对，请检查是否抄全。',
            JoinError.expired => '这个邀请码已过期，请对方重新生成。',
            JoinError.ownInvitation => '这是你自己的邀请码。',
            JoinError.alreadyJoining => '已经在用这个邀请码配对了。',
          };
      if (_joinError == null) _codeController.clear();
    });
  }

  void _onNotice(PairingNotice notice) {
    switch (notice.kind) {
      case PairingNoticeKind.contactAdded:
        _toast('已添加联系人：${notice.contact?.name ?? ''}');
      case PairingNoticeKind.declinedByPeer:
        _toast('对方拒绝了配对请求');
      case PairingNoticeKind.failed:
        if (notice.failure == PairingFailure.cancelled) return;
        _toast(
          describePairingFailure(notice.failure, asInviter: notice.asInviter),
        );
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    // 不用 AlertDialog：它要算固有宽度，而二维码控件不支持。
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('添加联系人', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(child: _buildBody(context)),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final requests = _manager.incomingRequests;
    final joins = _manager.joins;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final request in requests) _buildRequest(request),
        _section('我的名字', first: true),
        TextField(
          controller: _nameController,
          maxLength: 64,
          decoration: const InputDecoration(
            hintText: '配对时显示给对方（可留空）',
            border: OutlineInputBorder(),
            counterText: '',
            isDense: true,
          ),
          onEditingComplete: () {
            unawaited(_saveName());
            FocusScope.of(context).unfocus();
          },
          onTapOutside: (_) => unawaited(_saveName()),
        ),
        _section('输入对方的邀请码'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _codeController,
                decoration: InputDecoration(
                  hintText: '粘贴邀请码',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  errorText: _joinError,
                  errorMaxLines: 2,
                ),
                onSubmitted: (_) => unawaited(_join()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _joining ? null : () => unawaited(_join()),
              child: const Text('配对'),
            ),
          ],
        ),
        for (final join in joins) _buildJoin(join),
        _section('让对方添加我'),
        _buildInvitation(),
      ],
    );
  }

  Widget _section(String title, {bool first = false}) => Padding(
    padding: EdgeInsets.only(top: first ? 0 : 20, bottom: 8),
    child: Text(
      title,
      style: const TextStyle(
        color: AppTheme.darkGray,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    ),
  );

  Widget _buildRequest(IncomingPairRequest request) {
    final name = request.name.isEmpty ? '（未填名字）' : request.name;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.black, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$name 请求添加你',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          const Text(
            '安全码（和对方屏幕上的核对一致再批准）：',
            style: TextStyle(color: AppTheme.darkGray, fontSize: 12),
          ),
          const SizedBox(height: 4),
          SelectableText(
            request.safetyCode,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => _manager.reject(request.inviteId),
                child: const Text('拒绝'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => unawaited(_manager.approve(request.inviteId)),
                child: const Text('批准'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildJoin(OutgoingJoin join) {
    final text = switch (join.status) {
      PairingStatus.connecting => '正在连接…',
      PairingStatus.waiting => '已发出请求，等待对方批准',
      PairingStatus.responding => '正在完成配对…',
      _ => '处理中…',
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, color: AppTheme.darkGray),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(_manager.cancelJoin(join.inviteId)),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _buildInvitation() {
    final invitation = _invitation;
    if (invitation == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: _invitationError == null
              ? const CircularProgressIndicator(strokeWidth: 2)
              : TextButton(
                  onPressed: () => unawaited(_loadInvitation()),
                  child: Text('${_invitationError!}，点击重试'),
                ),
        ),
      );
    }
    final code = invitation.encode();
    final registered = _manager.isRegistered(invitation);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(child: QrImageView(data: code, size: 180)),
        const SizedBox(height: 8),
        SelectableText(
          code,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                registered ? '可以使用 · 24 小时内有效 · 只能用一次' : '正在连接中继，连上后对方才能使用…',
                style: const TextStyle(color: AppTheme.midGray, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: code)));
                _toast('邀请码已复制');
              },
              child: const Text('复制'),
            ),
          ],
        ),
      ],
    );
  }
}
