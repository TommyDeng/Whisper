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
  return showTermDialog<void>(
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
    // 已经有没用掉的邀请码就直接显示，不等下一帧。
    _invitation = _manager.openInvitation;
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
    // TermDialog 不算固有宽度，二维码控件才放得进去。
    return TermDialog(
      title: '添加联系人',
      tag: 'PAIR_',
      content: _buildBody(context),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
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
          style: const TextStyle(color: AppTheme.text, fontSize: 14),
          decoration: InputDecoration(
            hintText: '配对时显示给对方（可留空）',
            counterText: '',
            isDense: true,
            prefixIcon: _prompt(),
            prefixIconConstraints: const BoxConstraints(),
          ),
          onEditingComplete: () {
            unawaited(_saveName());
            FocusScope.of(context).unfocus();
          },
          onTapOutside: (_) => unawaited(_saveName()),
        ),
        _section('让对方添加我'),
        _buildInvitation(),
        const SizedBox(height: 20),
        const Row(
          children: [
            Expanded(child: Divider()),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: TagLabel('// 添加对方', color: AppTheme.text3),
            ),
            Expanded(child: Divider()),
          ],
        ),
        _section('输入对方的邀请码', top: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _codeController,
                style: AppTheme.mono(color: AppTheme.text, size: 13.5),
                decoration: InputDecoration(
                  hintText: '粘贴邀请码',
                  isDense: true,
                  errorText: _joinError,
                  errorMaxLines: 2,
                  prefixIcon: _prompt(),
                  prefixIconConstraints: const BoxConstraints(),
                ),
                onSubmitted: (_) => unawaited(_join()),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 42,
              child: FilledButton(
                onPressed: _joining ? null : () => unawaited(_join()),
                child: const Text('配对'),
              ),
            ),
          ],
        ),
        for (final join in joins) _buildJoin(join),
      ],
    );
  }

  /// 输入框开头的终端提示符。
  Widget _prompt() => Padding(
    padding: const EdgeInsets.only(left: 12, right: 8),
    child: Text(
      '>',
      style: AppTheme.mono(
        color: AppTheme.accent,
        size: 14,
        weight: FontWeight.w600,
      ),
    ),
  );

  Widget _section(String title, {bool first = false, double top = 20}) =>
      Padding(
        padding: EdgeInsets.only(top: first ? 0 : top, bottom: 8),
        child: Text(
          title,
          style: const TextStyle(
            color: AppTheme.text2,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      );

  Widget _buildRequest(IncomingPairRequest request) {
    final name = request.name.isEmpty ? '（未填名字）' : request.name;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.field,
        borderRadius: AppTheme.corners,
        border: Border.all(color: AppTheme.amber),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ContactMark(
                name: request.name,
                online: true,
                ring: AppTheme.field,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$name 请求添加你',
                      style: const TextStyle(
                        color: AppTheme.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '安全码（和对方屏幕上的核对一致再批准）：',
                      style: TextStyle(color: AppTheme.text2, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.panel,
              borderRadius: AppTheme.corners,
              border: Border.all(color: AppTheme.border),
            ),
            child: SelectableText(
              request.safetyCode,
              textAlign: TextAlign.center,
              style: AppTheme.mono(
                color: AppTheme.amber,
                size: 15,
                weight: FontWeight.w600,
                letterSpacing: 1.5,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                style: AppTheme.dangerButton,
                onPressed: () => _manager.reject(request.inviteId),
                child: const Text('拒绝'),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: () => unawaited(_manager.approve(request.inviteId)),
                icon: const Icon(Icons.done),
                label: const Text('批准'),
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
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: AppTheme.field,
        borderRadius: AppTheme.corners,
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13.5, color: AppTheme.text),
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

  /// 二维码只在邀请码变了时重画；配对状态一变整个对话框都会重建，二维码不跟着重算。
  String? _qrCode;
  Widget? _qr;

  Widget _qrFor(String code) {
    if (_qrCode != code || _qr == null) {
      _qrCode = code;
      // 二维码要深色码点配浅底，扫码的设备才认得出。
      _qr = RepaintBoundary(
        key: ValueKey(code),
        child: QrImageView(
          data: code,
          size: _qrSize,
          padding: const EdgeInsets.all(10),
          backgroundColor: AppTheme.textBright,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: AppTheme.bg,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: AppTheme.bg,
          ),
        ),
      );
    }
    return _qr!;
  }

  static const double _qrSize = 164;

  /// 邀请码文本的样式；生成前用同样长度的占位文字撑住高度，生成后对话框不跳。
  static final TextStyle _codeStyle = AppTheme.mono(
    color: AppTheme.accent,
    size: 12.5,
    weight: FontWeight.w500,
    height: 1.5,
  );

  /// 编码后的邀请码长度（1 + 32 + 16 + 4 字节的 Base32）。
  static final String _codePlaceholder = 'X' * 85;

  Widget _buildInvitation() {
    final invitation = _invitation;
    final code = invitation?.encode();
    final registered = invitation != null && _manager.isRegistered(invitation);

    // 还没生成时整块的大小和生成后一样，只是二维码位置先转圈，文字先透明占位。
    final Widget qrSlot = code != null
        ? _qrFor(code)
        : SizedBox.square(
            key: const ValueKey('qr-pending'),
            dimension: _qrSize,
            child: Center(
              child: _invitationError == null
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : TextButton(
                      onPressed: () => unawaited(_loadInvitation()),
                      child: Text('${_invitationError!}，点击重试'),
                    ),
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.accentSoft,
            borderRadius: AppTheme.corners,
            border: Border.all(color: AppTheme.accent),
            boxShadow: AppTheme.glow,
          ),
          child: Column(
            children: [
              AnimatedSwitcher(duration: Motion.medium, child: qrSlot),
              const SizedBox(height: 12),
              if (code != null)
                SelectableText(
                  code,
                  textAlign: TextAlign.center,
                  style: _codeStyle,
                )
              else
                Text(
                  _codePlaceholder,
                  textAlign: TextAlign.center,
                  style: _codeStyle.copyWith(color: Colors.transparent),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                code == null
                    ? '正在生成邀请码…'
                    : registered
                    ? '可以使用 · 24 小时内有效 · 只能用一次'
                    : '正在连接中继，连上后对方才能使用…',
                style: TextStyle(
                  color: code == null || registered
                      ? AppTheme.text2
                      : AppTheme.amber,
                  fontSize: 12,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: code == null
                  ? null
                  : () {
                      unawaited(Clipboard.setData(ClipboardData(text: code)));
                      _toast('邀请码已复制');
                    },
              icon: const Icon(Icons.copy),
              label: const Text('复制'),
            ),
          ],
        ),
      ],
    );
  }
}
