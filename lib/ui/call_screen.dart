/// 耳语 Whisper - 通话界面（Stage 3 已打通信令层）
///
/// 使用 CallController 与信令服务器建立 WebSocket 连接，
/// 通过 WebRTC P2P 进行 1:1 语音通话。
/// 黑白/单色细线条风格，安全状态常驻显示。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../contact/contact.dart';
import '../contact/contact_model.dart';
import '../session/call_controller.dart';
import '../signaling/address.dart';
import 'app_theme.dart';

/// 通话界面
class CallScreen extends StatefulWidget {
  final String contactName;
  final Contact contact;

  const CallScreen({super.key, required this.contactName, required this.contact});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final CallController _controller;
  final _urlController = TextEditingController(text: 'ws://192.168.31.236:8787');
  final _roomController = TextEditingController();
  bool _isConnecting = false;
  String? _connectError;

  @override
  void initState() {
    super.initState();
    _controller = CallController()
      ..signalingUrl = _urlController.text
      ..roomCode = widget.contact.deviceId;
    _roomController.text = _controller.roomCode;
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _urlController.dispose();
    _roomController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    // 对端挂断导致信令状态变为已断开，自动返回通话列表
    if (_controller.signalingState == '已断开') {
      unawaited(_controller.disconnect());
      Navigator.of(context).pop();
      return;
    }
    setState(() {});
  }

  Future<void> _connect() async {
    setState(() {
      _isConnecting = true;
      _connectError = null;
    });
    _controller.signalingUrl = _urlController.text.trim();
    _controller.roomCode = _roomController.text.trim();
    try {
      await _controller.connect();
    } catch (e) {
      setState(() {
        _connectError = '$e';
      });
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  Future<void> _disconnect() async {
    await _controller.disconnect();
    if (mounted) setState(() {});
  }

  void _generateRoomCode() {
    final code = generateRoomCode(math.Random.secure());
    _roomController.text = code;
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final connected = c.signalingState == '已连接';
    final calling = c.iceState == 'checking' ||
        c.pcState == 'connecting';
    final inCall = c.pcState == 'connected' || c.remoteAudio;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            SecurityIcon(
              status: widget.contact.isVerified
                  ? SecurityStatus.verified
                  : SecurityStatus.unverified,
              size: 14,
            ),
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
      ),
      body: Column(
        children: [
          // 信令连接区域
          Container(
            padding: const EdgeInsets.all(16),
            color: AppTheme.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '信令地址',
                      style: TextStyle(
                        color: AppTheme.darkGray,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _urlController,
                        enabled: !connected,
                        style: const TextStyle(
                          color: AppTheme.black,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      '房间码',
                      style: TextStyle(
                        color: AppTheme.darkGray,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _roomController,
                        enabled: !connected,
                        style: const TextStyle(
                          color: AppTheme.black,
                          fontSize: 14,
                          fontFamily: 'monospace',
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!connected)
                      OutlinedButton(
                        onPressed: _generateRoomCode,
                        child: const Text('生成'),
                      )
                    else
                      OutlinedButton(
                        onPressed: () {
                          final data = ClipboardData(text: _roomController.text);
                          Clipboard.setData(data);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('房间码已复制'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        child: const Text('复制'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (!connected)
                      FilledButton(
                        onPressed: _isConnecting ? null : _connect,
                        child: _isConnecting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('连接信令'),
                      )
                    else
                      OutlinedButton(
                        onPressed: _disconnect,
                        child: const Text('断开'),
                      ),
                    const SizedBox(width: 8),
                    if (_connectError != null)
                      Expanded(
                        child: Text(
                          _connectError!,
                          style: const TextStyle(
                            color: AppTheme.red,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '信令 ${c.signalingState} · 角色 ${c.role} · 人数 ${c.peerCount}',
                  style: const TextStyle(
                    color: AppTheme.midGray,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          // 通话主区域
          Expanded(
            child: connected ? _buildCallBody(c, inCall, calling) : _buildWaitingBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitingBody() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.call,
            size: 48,
            color: AppTheme.midGray,
          ),
          const SizedBox(height: 12),
          Text(
            '等待连接信令',
            style: const TextStyle(
              color: AppTheme.darkGray,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '两端输入相同房间码并连接，即可建立语音通话',
            style: const TextStyle(
              color: AppTheme.midGray,
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildCallBody(CallController c, bool inCall, bool calling) {
    return Column(
      children: [
        // 状态区域
        Expanded(
          flex: 2,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 24),
              // 安全状态图标（常驻显示）
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SecurityIcon(
                    status: widget.contact.isVerified
                        ? SecurityStatus.verified
                        : SecurityStatus.unverified,
                    size: 14,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '连接路径：${c.pathLabel}',
                    style: const TextStyle(
                      color: AppTheme.midGray,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              // 联系人名称
              Text(
                widget.contactName,
                style: const TextStyle(
                  color: AppTheme.black,
                  fontSize: 32,
                  fontWeight: FontWeight.w400,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                calling ? '呼叫中…' : (inCall ? '通话中' : '等待对端'),
                style: const TextStyle(
                  color: AppTheme.darkGray,
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 32),
              // 连接详情
              if (c.pathDetail.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    c.pathDetail,
                    style: const TextStyle(
                      color: AppTheme.darkGray,
                      fontSize: 11,
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              // 音频状态
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    c.remoteAudio ? Icons.volume_up : Icons.volume_off,
                    size: 16,
                    color: c.remoteAudio ? AppTheme.black : AppTheme.midGray,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    c.remoteAudio ? '已收到远端音频' : '等待远端音频',
                    style: const TextStyle(
                      color: AppTheme.midGray,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // 控制区域
        Expanded(
          flex: 1,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 静音按钮
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppTheme.lightGray,
                    width: 1,
                  ),
                ),
                child: IconButton(
                  icon: Icon(
                    c.muted ? Icons.mic_off : Icons.mic,
                    size: 24,
                  ),
                  onPressed: c.toggleMute,
                  color: AppTheme.black,
                  padding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(height: 32),
              // 挂断按钮
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppTheme.black,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.call_end, size: 24),
                  onPressed: () {
                    unawaited(_controller.hangup());
                    Navigator.of(context).pop();
                  },
                  color: AppTheme.white,
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
