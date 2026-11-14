/// 通话界面：有通话时在窗口顶部显示一条不挡住聊天的栏，来电是横幅。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../app_services.dart';
import '../call/call_audio.dart';
import '../call/call_service.dart';
import '../call/call_sound.dart';
import '../call/message_sound.dart';
import '../voice/ice_strategy.dart';
import 'app_theme.dart';

/// 包在应用最外层（MaterialApp.builder），监听通话状态和来信提示音。
class CallHost extends StatefulWidget {
  const CallHost({super.key, required this.child});

  final Widget child;

  @override
  State<CallHost> createState() => _CallHostState();
}

class _CallHostState extends State<CallHost> with WidgetsBindingObserver {
  final _services = AppServices.instance;
  late CallSnapshot _snapshot = _services.calls.snapshot;
  StreamSubscription<CallSnapshot>? _changes;
  StreamSubscription<IcePathType?>? _paths;
  StreamSubscription<double>? _levels;
  StreamSubscription<RTCVideoRenderer?>? _renderers;
  StreamSubscription<RTCVideoRenderer?>? _localRenderers;
  StreamSubscription<CallAudioStats>? _audioStatsSub;
  StreamSubscription<({String sessionId, String msgId, bool isFile})>?
  _incomingChat;
  StreamSubscription<String>? _incomingFiles;
  final _sounds = CallSound();
  final _messageSound = MessageSound();
  Timer? _ticker;
  Timer? _autoDismiss;
  IcePathType? _path;
  double _micLevel = 0;
  RTCVideoRenderer? _remoteRenderer;
  RTCVideoRenderer? _localRenderer;
  CallAudioStats _audioStats = const CallAudioStats();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _changes = _services.calls.changes.listen(_onChange);
    _paths = _services.callPaths.listen((path) {
      if (mounted) setState(() => _path = path);
    });
    _levels = _services.callMicLevels.listen((level) {
      if (mounted) setState(() => _micLevel = level);
    });
    _renderers = _services.callRemoteRenderers.listen((renderer) {
      if (mounted) setState(() => _remoteRenderer = renderer);
    });
    _localRenderers = _services.callLocalRenderers.listen((renderer) {
      if (mounted) setState(() => _localRenderer = renderer);
    });
    _audioStatsSub = _services.callAudioStats.listen((stats) {
      if (mounted) setState(() => _audioStats = stats);
    });
    _incomingChat = _services.messaging.incomingChat.listen((event) {
      _onIncoming(event.sessionId);
    });
    _incomingFiles = _services.files.incomingArrivals.listen(_onIncoming);
    unawaited(_sounds.sync(_snapshot.phase));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _changes?.cancel();
    _paths?.cancel();
    _levels?.cancel();
    _renderers?.cancel();
    _localRenderers?.cancel();
    _audioStatsSub?.cancel();
    _incomingChat?.cancel();
    _incomingFiles?.cancel();
    _ticker?.cancel();
    _autoDismiss?.cancel();
    unawaited(_sounds.dispose());
    unawaited(_messageSound.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _services.uiFocus.windowFocused = state == AppLifecycleState.resumed;
  }

  void _onIncoming(String sessionId) {
    _maybeChime(sessionId);
    unawaited(_services.window.flashIfNeeded());
  }

  void _maybeChime(String sessionId) {
    final focus = _services.uiFocus;
    if (shouldPlayMessageSound(
      fromSelf: false,
      sessionId: sessionId,
      visibleSessionId: focus.visibleSessionId,
      windowFocused: focus.windowFocused,
      callPhase: _services.calls.snapshot.phase,
    )) {
      unawaited(_messageSound.chime());
    }
  }

  void _onChange(CallSnapshot snapshot) {
    if (!mounted) return;
    // 来电和新消息一样要闪任务栏和托盘：窗口在后台或关到托盘时，光靠铃声容易漏。
    if (snapshot.phase == CallPhase.incoming &&
        _snapshot.phase != CallPhase.incoming) {
      unawaited(_services.window.flashIfNeeded());
    }
    setState(() {
      _snapshot = snapshot;
      if (snapshot.phase == CallPhase.idle ||
          snapshot.phase == CallPhase.incoming) {
        _micLevel = 0;
      }
    });
    unawaited(_sounds.sync(snapshot.phase));

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
        if (current.phase == CallPhase.ended && current.callId == callId) {
          _services.calls.dismiss();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_snapshot.phase == CallPhase.idle &&
        _remoteRenderer == null &&
        _localRenderer == null) {
      return widget.child;
    }
    return Stack(
      children: [
        Column(
          children: [
            if (_snapshot.phase != CallPhase.idle)
              CallBar(
                snapshot: _snapshot,
                path: _path,
                micLevel: _micLevel,
                audioStats: _audioStats,
              ),
            Expanded(child: widget.child),
          ],
        ),
        if (_remoteRenderer != null)
          Positioned(
            left: 0,
            top: 0,
            width: 1,
            height: 1,
            child: IgnorePointer(child: RTCVideoView(_remoteRenderer!)),
          ),
        if (_localRenderer != null)
          Positioned(
            left: 1,
            top: 0,
            width: 1,
            height: 1,
            child: IgnorePointer(child: RTCVideoView(_localRenderer!)),
          ),
      ],
    );
  }
}

/// 窗口顶部的通话条：状态、计时、麦克风电平、静音和挂断；来电则是接听/拒接横幅。
class CallBar extends StatelessWidget {
  const CallBar({
    super.key,
    required this.snapshot,
    required this.path,
    required this.micLevel,
    this.audioStats = const CallAudioStats(),
    this.now,
  });

  final CallSnapshot snapshot;
  final IcePathType? path;

  /// 本端麦克风电平，0.0–1.0。静音或尚无采集时为 0。
  final double micLevel;

  /// 收发字节与电平，显示在状态旁供两端对照。
  final CallAudioStats audioStats;

  /// 用来算通话时长；为空则取当前时间。测试可传入固定值。
  final DateTime? now;

  CallService get _calls => AppServices.instance.calls;

  @override
  Widget build(BuildContext context) {
    final name = snapshot.contact?.name ?? '';
    final displayName = name.isEmpty ? '未命名联系人' : name;
    final status = callStatusText(snapshot, now ?? DateTime.now());
    final active = snapshot.phase == CallPhase.active;
    final live = active && !snapshot.reconnecting;
    final showStats =
        active ||
        snapshot.phase == CallPhase.connecting ||
        snapshot.phase == CallPhase.outgoing;
    final detailStyle = AppTheme.mono(color: AppTheme.text3, size: 11);
    // 左侧色带和状态文字：红＝来电，绿＝通话中，黄＝还没接通或在重连，暗＝已结束。
    final Color tone = switch (snapshot.phase) {
      CallPhase.incoming => AppTheme.alert,
      CallPhase.active => live ? AppTheme.accent : AppTheme.amber,
      CallPhase.outgoing || CallPhase.connecting => AppTheme.amber,
      CallPhase.ended || CallPhase.idle => AppTheme.border,
    };
    final ended = snapshot.phase == CallPhase.ended;
    return Material(
      color: AppTheme.panel,
      child: SafeArea(
        bottom: false,
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.fromLTRB(13, 9, 12, 9),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: tone, width: 3),
              bottom: const BorderSide(color: AppTheme.divider),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: live ? AppTheme.accentSoft : AppTheme.field,
                  borderRadius: AppTheme.corners,
                  border: Border.all(color: tone),
                ),
                child: Icon(
                  ended ? Icons.call_end_outlined : Icons.call_outlined,
                  size: 18,
                  color: ended ? AppTheme.text3 : tone,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.text,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          status,
                          style: TextStyle(
                            color: ended ? AppTheme.text2 : tone,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            fontFeatures: AppTheme.tabularFigures,
                          ),
                        ),
                      ],
                    ),
                    if (active && path != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.lock_outline,
                            size: 12,
                            color: AppTheme.text2,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '端到端加密 · ${callPathLabel(path!)}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.text2,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (showStats) ...[
                      const SizedBox(height: 3),
                      Text(
                        audioStats.compactLabel,
                        overflow: TextOverflow.ellipsis,
                        style: detailStyle,
                      ),
                      if (audioStats.playoutDevice != null) ...[
                        const SizedBox(height: 1),
                        Text(
                          '播放设备：${audioStats.playoutDevice}',
                          overflow: TextOverflow.ellipsis,
                          style: detailStyle,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              if (_showMicLevel(snapshot)) ...[
                const SizedBox(width: 8),
                MicLevelBar(level: snapshot.muted ? 0 : micLevel),
              ],
              const SizedBox(width: 12),
              ..._actions(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _actions() {
    switch (snapshot.phase) {
      case CallPhase.incoming:
        return [
          _BarButton(
            label: '拒接',
            icon: Icons.call_end,
            style: AppTheme.dangerButton,
            onPressed: () => unawaited(_calls.decline()),
          ),
          const SizedBox(width: 8),
          _BarButton(
            label: '接听',
            icon: Icons.call,
            style: AppTheme.primaryButton,
            glow: AppTheme.glow,
            onPressed: () => unawaited(_calls.accept()),
          ),
        ];
      case CallPhase.outgoing:
      case CallPhase.connecting:
      case CallPhase.active:
        return [
          _BarButton(
            label: snapshot.muted ? '取消静音' : '静音',
            icon: snapshot.muted ? Icons.mic_off : Icons.mic_none,
            // 已静音时按钮亮起来，提醒对方现在听不到你。
            style: snapshot.muted
                ? AppTheme.secondaryButton
                : AppTheme.plainButton,
            onPressed: () => _calls.setMuted(!snapshot.muted),
          ),
          const SizedBox(width: 8),
          _BarButton(
            label: '挂断',
            icon: Icons.call_end,
            style: AppTheme.dangerFilledButton,
            glow: AppTheme.alertGlow,
            onPressed: () => unawaited(_calls.hangup()),
          ),
        ];
      case CallPhase.ended:
        return [
          _BarButton(
            label: '关闭',
            icon: Icons.close,
            style: AppTheme.plainButton,
            onPressed: _calls.dismiss,
          ),
        ];
      case CallPhase.idle:
        return const [];
    }
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.style,
    this.glow,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final ButtonStyle style;

  /// 实心按钮外面的辉光。
  final List<BoxShadow>? glow;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: AppTheme.corners,
        boxShadow: glow,
      ),
      child: TextButton.icon(
        style: style.copyWith(
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 14),
          ),
        ),
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      ),
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
      if (snapshot.reconnecting) return '正在重新连接…';
      final started = snapshot.connectedAt;
      return started == null
          ? '通话中'
          : formatCallDuration(now.difference(started));
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

bool _showMicLevel(CallSnapshot snapshot) {
  return snapshot.phase == CallPhase.outgoing ||
      snapshot.phase == CallPhase.connecting ||
      snapshot.phase == CallPhase.active;
}

/// 本端麦克风电平条，供通话界面使用；[level] 按 0.0–1.0 解读。
class MicLevelBar extends StatelessWidget {
  const MicLevelBar({super.key, required this.level});

  final double level;

  static const _segments = 8;

  @override
  Widget build(BuildContext context) {
    final filled = (level.clamp(0.0, 1.0) * _segments).ceil();
    return SizedBox(
      width: 56,
      height: 12,
      child: Row(
        // 不拉伸的话每一格高度是 0，整条电平条看不见。
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < _segments; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: i < filled ? AppTheme.accent : AppTheme.border,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
