/// 配对页面：邀请码生成、显示、输入、扫码、手动批准。
///
/// 界面分三块：
/// - 上方：邀请码生成/显示（二维码 + Base32 文本）
/// - 中方：邀请码输入（粘贴对方邀请码）
/// - 下方：配对状态 + 批准/拒绝按钮

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'pairing_manager.dart';

/// 配对页面。
class PairingPage extends StatefulWidget {
  const PairingPage({super.key, required this.pairingManager});

  final PairingManager pairingManager;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _invitationController = TextEditingController();
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    widget.pairingManager.stateStream.listen((_) => setState(() {}));
  }

  @override
  void dispose() {
    _invitationController.dispose();
    super.dispose();
  }

  Future<void> _generateInvitation() async {
    setState(() => _isGenerating = true);
    try {
      await widget.pairingManager.generateInvitation();
    } finally {
      setState(() => _isGenerating = false);
    }
  }

  Future<void> _useInvitation() async {
    final code = _invitationController.text.trim();
    if (code.isEmpty) return;
    await widget.pairingManager.useInvitation(code);
  }

  Future<void> _approve() async {
    final request = widget.pairingManager.incomingRequest;
    if (request == null) return;
    await widget.pairingManager.approveRequest(request.requestId);
  }

  Future<void> _reject() async {
    final request = widget.pairingManager.incomingRequest;
    if (request == null) return;
    await widget.pairingManager.rejectRequest(request.requestId);
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.pairingManager;
    final invitation = manager.myInvitation;
    final request = manager.incomingRequest;

    return Scaffold(
      appBar: AppBar(
        title: const Text('配对 - 耳语 Whisper'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 邀请码生成区域
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '生成邀请码',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    if (invitation != null) ...[
                      QrImageView(
                        data: invitation.encode(),
                        version: QrVersions.auto,
                        size: 200,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        invitation.encode(),
                        style: const TextStyle(
                          fontSize: 14,
                          fontFamily: 'monospace',
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '有效期：${invitation.ttl} 秒（一次性，24 小时）',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isGenerating ? null : _generateInvitation,
                            icon: _isGenerating
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.qr_code),
                            label: const Text('生成邀请码'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // 邀请码输入区域
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '输入对方邀请码',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _invitationController,
                      decoration: const InputDecoration(
                        labelText: '邀请码（Base32）',
                        hintText: '粘贴对方提供的邀请码',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 1,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _useInvitation,
                            icon: const Icon(Icons.login),
                            label: const Text('加入配对'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // 配对状态区域
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '配对状态',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    _buildStatusWidget(manager),
                    const SizedBox(height: 12),
                    if (request != null) ...[
                      const Text(
                        '收到配对请求',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '发起方：${request.inviterPublicKey.substring(0, 12)}...',
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _approve(),
                              icon: const Icon(Icons.check),
                              label: const Text('批准'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _reject(),
                              icon: const Icon(Icons.close),
                              label: const Text('拒绝'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusWidget(PairingManager manager) {
    switch (manager.state) {
      case PairingState.idle:
        return const Text('未开始配对');
      case PairingState.generating:
        return const Row(
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Text('正在生成邀请码...'),
          ],
        );
      case PairingState.waiting:
        return const Text('等待对方加入...');
      case PairingState.entering:
        return const Text('正在输入邀请码...');
      case PairingState.requesting:
        return const Text('正在发送配对请求...');
      case PairingState.approving:
        return const Text('等待邀请人批准...');
      case PairingState.approved:
        return const Text(
          '配对成功！',
          style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
        );
      case PairingState.failed:
        return Text(
          '配对失败：${manager.error}',
          style: const TextStyle(color: Colors.red),
        );
    }
  }
}
