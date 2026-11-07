/// 耳语语音通话界面。

import 'package:flutter/material.dart';

import 'voice_call.dart';

/// 语音通话页面
class VoicePage extends StatefulWidget {
  const VoicePage({super.key, required this.call});

  final VoiceCall call;

  @override
  State<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<VoicePage> {
  CallState _state = CallState.idle;
  IceCandidateInfo? _path;
  bool _muted = false;

  @override
  void initState() {
    super.initState();
    widget.call.initLocalAudio().catchError((_) {});
    widget.call.onStateChanged = (s) => setState(() => _state = s);
    widget.call.onPathChanged = (IceCandidateInfo p) => setState(() => _path = p);
  }

  @override
  void dispose() {
    widget.call.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('语音通话 - 耳语 Whisper'),
        automaticallyImplyLeading: true,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildStatusCard(),
            const SizedBox(height: 32),
            _buildPathCard(),
            const SizedBox(height: 32),
            _buildControlButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Text(
              '通话状态',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Icon(
              _stateIcon(_state),
              size: 64,
              color: _stateColor(_state),
            ),
            const SizedBox(height: 16),
            Text(
              _stateText(_state),
              style: const TextStyle(fontSize: 20),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPathCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '连接路径',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            if (_path != null) ...[
              Row(
                children: [
                  Icon(
                    _pathIcon(_path!.type),
                    color: _pathColor(_path!.type),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _path!.label,
                    style: const TextStyle(fontSize: 18),
                  ),
                ],
              ),
            ] else ...[
              const Text(
                '未建立连接',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildControlButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FloatingActionButton(
          onPressed: widget.call.toggleMute,
          backgroundColor: _muted ? Colors.orange : null,
          child: Icon(_muted ? Icons.mic_off : Icons.mic),
        ),
        const SizedBox(width: 16),
        FloatingActionButton(
          onPressed: () {
            widget.call.hangup();
            Navigator.of(context).pop();
          },
          backgroundColor: Colors.red,
          child: const Icon(Icons.call_end),
        ),
      ],
    );
  }

  IconData _stateIcon(CallState state) {
    switch (state) {
      case CallState.idle:
        return Icons.call;
      case CallState.calling:
        return Icons.phone;
      case CallState.connected:
        return Icons.phone_android;
      case CallState.disconnected:
        return Icons.call_end;
      case CallState.failed:
        return Icons.error;
    }
  }

  Color _stateColor(CallState state) {
    switch (state) {
      case CallState.idle:
        return Colors.grey;
      case CallState.calling:
        return Colors.blue;
      case CallState.connected:
        return Colors.green;
      case CallState.disconnected:
        return Colors.grey;
      case CallState.failed:
        return Colors.red;
    }
  }

  String _stateText(CallState state) {
    switch (state) {
      case CallState.idle:
        return '未开始';
      case CallState.calling:
        return '呼叫中...';
      case CallState.connected:
        return '已连接';
      case CallState.disconnected:
        return '已断开';
      case CallState.failed:
        return '连接失败';
    }
  }

  IconData _pathIcon(IcePathType type) {
    switch (type) {
      case IcePathType.lan:
        return Icons.wifi;
      case IcePathType.zerotier:
        return Icons.router;
      case IcePathType.srflx:
        return Icons.signal_cellular_alt;
      case IcePathType.relay:
        return Icons.cloud;
      case IcePathType.unknown:
        return Icons.help;
    }
  }

  Color _pathColor(IcePathType type) {
    switch (type) {
      case IcePathType.lan:
        return Colors.green;
      case IcePathType.zerotier:
        return Colors.blue;
      case IcePathType.srflx:
        return Colors.orange;
      case IcePathType.relay:
        return Colors.red;
      case IcePathType.unknown:
        return Colors.grey;
    }
  }
}
