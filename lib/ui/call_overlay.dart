/// 通话界面：有通话（呼出、来电、通话中、刚结束）时盖在整个应用上面。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../call/call_service.dart';
import '../voice/ice_strategy.dart';
import 'app_theme.dart';

/// 包在应用最外层（MaterialApp.builder），监听通话状态。
class CallHost extends StatefulWidget {
  const CallHost({super.key, required this.child});

  final Widget child;

  @override
  State<CallHost> createState() => _CallHostState();
}

class _CallHostState extends State<CallHost> {
  final _services = AppServices.instance;
  late CallSnapshot _snapshot = _services.calls.snapshot;
  StreamSubscription<CallSnapshot>? _changes;
  StreamSubscription<IcePathType?>? _paths;
  Timer? _ticker;
  Timer? _autoDismiss;
  IcePathType? _path;

  @override
  void initState() {
    super.initState();
    _changes = _services.calls.changes.listen(_onChange);
    _paths = _services.callPaths.listen((path) {
      if (mounted) setState(() => _path = path);
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    _paths?.cancel();
    _ticker?.cancel();
    _autoDismiss?.cancel();
    super.dispose();
  }

  void _onChange(CallSnapshot snapshot) {
    if (!mounted) return;
    setState(() => _snapshot = snapshot);

    // 通话中每秒刷新一次时长
    if (snapshot.phase == CallPhase.active) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }

    // 结束原因显示几秒后自动收起
    _autoDismiss?.cancel();
    _autoDismiss = null;
    if (snapshot.phase == CallPhase.ended) {
      final callId = snapshot.callId;
      _autoDismiss = Timer(const Duration(seconds: 3), () {
        final current = _services.calls.snapshot;
        if (current.phase == CallPhase.ended && current.callId == callId) _services.calls.dismiss();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_snapshot.phase == CallPhase.idle) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(child: _CallPanel(snapshot: _snapshot, path: _path)),
      ],
    );
  }
}

class _CallPanel extends StatelessWidget {
  const _CallPanel({required this.snapshot, required this.path});

  final CallSnapshot snapshot;
  final IcePathType? path;

  CallService get _calls => AppServices.instance.calls;

  @override
  Widget build(BuildContext context) {
    final name = snapshot.contact?.name ?? '';
    return Material(
      color: AppTheme.white,
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            const Icon(Icons.person_outline, size: 64, color: AppTheme.darkGray),
            const SizedBox(height: 16),
            Text(
              name.isEmpty ? '未命名联系人' : name,
              style: const TextStyle(color: AppTheme.black, fontSize: 24, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            Text(
              callStatusText(snapshot, DateTime.now()),
              style: const TextStyle(color: AppTheme.darkGray, fontSize: 15),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 18,
              child: snapshot.phase == CallPhase.active && path != null
                  ? Text(
                      '端到端加密 · ${callPathLabel(path!)}',
                      style: const TextStyle(color: AppTheme.midGray, fontSize: 12),
                    )
                  : null,
            ),
            const Spacer(flex: 3),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: _buttons()),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  List<Widget> _buttons() {
    switch (snapshot.phase) {
      case CallPhase.incoming:
        return [
          _RoundButton(
            label: '拒接',
            icon: Icons.call_end,
            filled: AppTheme.red,
            onPressed: () => unawaited(_calls.decline()),
          ),
          const SizedBox(width: 64),
          _RoundButton(
            label: '接听',
            icon: Icons.call,
            filled: AppTheme.black,
            onPressed: () => unawaited(_calls.accept()),
          ),
        ];
      case CallPhase.outgoing:
      case CallPhase.connecting:
      case CallPhase.active:
        return [
          _RoundButton(
            label: snapshot.muted ? '取消静音' : '静音',
            icon: snapshot.muted ? Icons.mic_off : Icons.mic_none,
            filled: snapshot.muted ? AppTheme.darkGray : null,
            onPressed: () => _calls.setMuted(!snapshot.muted),
          ),
          const SizedBox(width: 64),
          _RoundButton(
            label: '挂断',
            icon: Icons.call_end,
            filled: AppTheme.red,
            onPressed: () => unawaited(_calls.hangup()),
          ),
        ];
      case CallPhase.ended:
        return [
          _RoundButton(label: '关闭', icon: Icons.close, onPressed: _calls.dismiss),
        ];
      case CallPhase.idle:
        return const [];
    }
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.label, required this.icon, required this.onPressed, this.filled});

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  /// 实心底色；为 null 时是白底细边框。
  final Color? filled;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: filled ?? AppTheme.white,
          shape: CircleBorder(
            side: filled == null ? const BorderSide(color: AppTheme.lightGray) : BorderSide.none,
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 64,
              height: 64,
              child: Icon(icon, color: filled == null ? AppTheme.black : AppTheme.white, size: 28),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: AppTheme.darkGray, fontSize: 12)),
      ],
    );
  }
}

/// 状态一行字。[now] 用来算通话时长。
String callStatusText(CallSnapshot snapshot, DateTime now) {
  switch (snapshot.phase) {
    case CallPhase.idle:
      return '';
    case CallPhase.outgoing:
      return snapshot.remoteRinging ? '对方响铃中…' : '正在呼叫…';
    case CallPhase.incoming:
      return '语音来电';
    case CallPhase.connecting:
      return '正在接通…';
    case CallPhase.active:
      final started = snapshot.connectedAt;
      return started == null ? '通话中' : formatCallDuration(now.difference(started));
    case CallPhase.ended:
      return callEndText(snapshot.endReason);
  }
}

String callEndText(CallEndReason? reason) {
  switch (reason) {
    case CallEndReason.hangup:
    case CallEndReason.remoteHangup:
    case null:
      return '通话已结束';
    case CallEndReason.rejected:
      return '对方已拒接';
    case CallEndReason.declined:
      return '已拒接';
    case CallEndReason.busy:
      return '对方正在通话中';
    case CallEndReason.offline:
      return '对方不在线';
    case CallEndReason.timeout:
      return '对方无应答';
    case CallEndReason.missed:
      return '未接来电';
    case CallEndReason.failed:
      return '通话连接失败';
  }
}

String formatCallDuration(Duration duration) {
  final seconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  String two(int value) => value.toString().padLeft(2, '0');
  final hours = seconds ~/ 3600;
  final rest = '${two(seconds % 3600 ~/ 60)}:${two(seconds % 60)}';
  return hours > 0 ? '$hours:$rest' : rest;
}

String callPathLabel(IcePathType path) {
  switch (path) {
    case IcePathType.lan:
      return '局域网直连';
    case IcePathType.zerotier:
      return 'ZeroTier 直连';
    case IcePathType.srflx:
      return '公网直连';
    case IcePathType.relay:
      return '云端中继';
    case IcePathType.unknown:
      return '路径未知';
  }
}
