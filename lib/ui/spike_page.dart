import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../session/call_controller.dart';
import '../signaling/address.dart';

class SpikePage extends StatefulWidget {
  const SpikePage({super.key, required this.controller});

  final CallController controller;

  @override
  State<SpikePage> createState() => _SpikePageState();
}

class _SpikePageState extends State<SpikePage> {
  late final TextEditingController _url;
  late final TextEditingController _room;
  late final TextEditingController _fallback;
  late final TextEditingController _message;
  int _sizeMiB = 8;
  int _chunkKiB = 16;

  @override
  void initState() {
    super.initState();
    final controller = widget.controller;
    _url = TextEditingController(text: controller.signalingUrl);
    _room = TextEditingController(text: controller.roomCode);
    _fallback = TextEditingController(text: '${controller.fallback.inSeconds}');
    _message = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.maybeAutorun();
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _room.dispose();
    _fallback.dispose();
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('耳语 WebRTC Spike')),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => _body(context, widget.controller),
      ),
    );
  }

  Widget _body(BuildContext context, CallController controller) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _section(
                '信令',
                [
                  TextField(
                    controller: _url,
                    decoration: const InputDecoration(
                      labelText: '信令地址',
                      helperText: '一台机器跑 wrangler 后，两台客户端都填 ws://那台机器的局域网IP:8787',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _room,
                    decoration: const InputDecoration(labelText: '房间码（粘贴同一串）'),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(onPressed: _generateRoom, child: const Text('生成房间码')),
                      FilledButton(onPressed: () => _connect(controller), child: const Text('连接')),
                      OutlinedButton(onPressed: controller.disconnect, child: const Text('断开')),
                      OutlinedButton(
                        onPressed: () {
                          controller.signalingUrl = _url.text.trim();
                          controller.checkHealth();
                        },
                        child: const Text('健康检查'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('信令 ${controller.signalingState} · 角色 ${controller.role} · 人数 ${controller.peerCount}'),
                ],
              ),
              _section('路径', [
                _pathBanner(controller.pathLabel),
                const SizedBox(height: 8),
                Text(controller.pathDetail),
                const SizedBox(height: 4),
                Text(controller.schedulerText),
                const SizedBox(height: 8),
                TextField(
                  controller: _fallback,
                  decoration: const InputDecoration(
                    labelText: '首选路径失败后放开其余候选（秒）',
                    helperText: '先只发局域网 host；没有局域网则等采集结束或 4 秒后发 ZeroTier；再过这段时间才发公网候选。',
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                Text('ICE ${controller.iceState} · PeerConnection ${controller.pcState}'),
                Text(
                  'DTLS-SRTP：开启（未关闭）。'
                  '状态 ${controller.dtlsState ?? '—'}'
                  '${controller.dtlsActive ? '，已连接' : ''}'
                  '。应用层 E2EE：本 spike 没有。',
                ),
                if (controller.dtlsCipher != null) Text('DTLS ${controller.dtlsCipher}'),
                if (controller.srtpCipher != null) Text('SRTP ${controller.srtpCipher}'),
                if (controller.localFingerprint != null) SelectableText('本机指纹 ${controller.localFingerprint}'),
                if (controller.remoteFingerprint != null) SelectableText('对端指纹 ${controller.remoteFingerprint}'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(onPressed: controller.hangup, child: const Text('挂断')),
                    OutlinedButton(onPressed: controller.recall, child: const Text('重新呼叫')),
                    OutlinedButton(onPressed: controller.refreshNics, child: const Text('刷新网卡')),
                  ],
                ),
              ]),
              _section('网卡', [
                if (controller.probeError != null) Text(controller.probeError!),
                if (controller.nics.isEmpty) const Text('尚未枚举到网卡'),
                for (final nic in controller.nics) Text(nic.label),
              ]),
              _section('音频', [
                Text(controller.micAvailable ? '麦克风已打开' : '麦克风未打开'),
                if (controller.micError != null) Text(controller.micError!),
                Text(controller.remoteAudio ? '已收到远端音频' : '还没有远端音频'),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: controller.toggleMute,
                  child: Text(controller.muted ? '取消静音' : '静音'),
                ),
              ]),
              _section('数据通道', [
                Text('通道 ${controller.dcState} · 分块 $_chunkKiB KiB'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final size in [8, 16, 64])
                      ChoiceChip(
                        label: Text('$size KiB'),
                        selected: _chunkKiB == size,
                        onSelected: (_) => setState(() => _chunkKiB = size),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _message,
                        decoration: const InputDecoration(labelText: '文字'),
                        onSubmitted: (_) => _sendText(controller),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: () => _sendText(controller), child: const Text('发送')),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final size in [1, 8, 32])
                      ChoiceChip(
                        label: Text('$size MiB'),
                        selected: _sizeMiB == size,
                        onSelected: (_) => setState(() => _sizeMiB = size),
                      ),
                    FilledButton(
                      onPressed: () {
                        controller.chunkSize = _chunkKiB * 1024;
                        controller.sendTestPayload(_sizeMiB * 1024 * 1024);
                      },
                      child: const Text('发送测试文件'),
                    ),
                    OutlinedButton(onPressed: () => _pickFile(controller), child: const Text('选择文件')),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '提交耗时 ${controller.lastSubmitMillis ?? '—'} ms · '
                  '接收 ${controller.lastReceiveMillis ?? '—'} ms · '
                  '${controller.lastMibps?.toStringAsFixed(2) ?? '—'} MiB/s · '
                  '校验 ${controller.lastHashOk == null ? '—' : (controller.lastHashOk! ? '通过' : '失败')}',
                ),
                if (controller.receivePath != null) SelectableText('接收文件 ${controller.receivePath}'),
                const SizedBox(height: 8),
                for (final line in controller.chat.take(12)) Text(line),
              ]),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 2,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLow),
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text('日志', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final line in controller.logs) Text(line),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...children,
        ]),
      ),
    );
  }

  Widget _pathBanner(String label) {
    final color = switch (label) {
      '局域网' => const Color(0xFF1B7F4E),
      'ZeroTier' => const Color(0xFF1D4E89),
      '公网 P2P' => const Color(0xFFB86E00),
      '中继' => const Color(0xFF9B2C2C),
      _ => const Color(0xFF5C6670),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: color,
      child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w600)),
    );
  }

  void _generateRoom() {
    final code = generateRoomCode(Random.secure());
    _room.text = code;
    Clipboard.setData(ClipboardData(text: code));
    widget.controller.log('已生成房间码 $code 并复制');
  }

  Future<void> _connect(CallController controller) async {
    controller.signalingUrl = _url.text.trim();
    controller.roomCode = _room.text.trim();
    final seconds = int.tryParse(_fallback.text.trim());
    if (seconds != null && seconds >= 0) controller.fallback = Duration(seconds: seconds);
    controller.chunkSize = _chunkKiB * 1024;
    try {
      await controller.connect();
    } catch (_) {}
  }

  Future<void> _sendText(CallController controller) async {
    await controller.sendText(_message.text);
    _message.clear();
  }

  Future<void> _pickFile(CallController controller) async {
    final file = await openFile();
    if (file == null || !mounted) return;
    controller.chunkSize = _chunkKiB * 1024;
    await controller.sendFileStream(name: file.name, size: await file.length(), chunks: file.openRead());
  }
}
