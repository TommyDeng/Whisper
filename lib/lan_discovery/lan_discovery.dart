/// 耳语局域网发现模块。
///
/// 基于 UDP 广播的局域网设备发现（mDNS 的轻量替代）。
/// 在同一局域网内，耳语客户端可通过广播发现彼此，无需手动输入 IP。
///
/// 注意：Flutter 桌面端 mDNS 原生支持有限，本实现使用 UDP 广播，
/// 适用于同一子网内的设备发现。

library lan_discovery;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 局域网发现的广播地址和端口
const String _broadcastAddress = '255.255.255.255';
const int _discoveryPort = 1900;

/// 发现的联系人信息
class DiscoveredPeer {
  const DiscoveredPeer({
    required this.ip,
    required this.name,
    required this.lastSeen,
  });

  final String ip;
  final String name;
  final DateTime lastSeen;
}

/// 局域网发现服务
class LanDiscovery {
  RawDatagramSocket? _socket;
  bool _isListening = false;
  final Map<String, DiscoveredPeer> _peers = {};
  final Duration _cacheTimeout = const Duration(minutes: 5);

  /// 当前发现的所有联系人
  List<DiscoveredPeer> get peers => _peers.values.toList()
    ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  /// 发现新联系人的回调
  void Function(DiscoveredPeer peer)? onPeerDiscovered;

  /// 开始监听局域网发现广播
  Future<void> startListening() async {
    if (_isListening) return;

    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _discoveryPort,
        reuseAddress: true,
      );
      _socket!.broadcastEnabled = true;

      _socket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _socket!.receive();
          if (datagram != null) {
            _handleDatagram(datagram.data, datagram.address.address);
          }
        }
      });

      _isListening = true;
    } catch (e) {
      // 广播在某些网络环境下可能不可用
      _isListening = false;
    }
  }

  /// 停止监听
  Future<void> stopListening() async {
    if (_socket != null) {
      _socket!.close();
      _socket = null;
    }
    _isListening = false;
  }
  Future<void> announce(String deviceName) async {
    if (_socket == null) return;

    final message = {
      'type': 'whisper-discover',
      'name': deviceName,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    final bytes = utf8.encode(jsonEncode(message));
    await _socket!.send(
      bytes,
      InternetAddress(_broadcastAddress),
      _discoveryPort,
    );
  }

  /// 定期广播（建议每 30 秒调用一次）
  Future<void> startPeriodicAnnounce(String deviceName, {Duration interval = const Duration(seconds: 30)}) async {
    while (_isListening) {
      await announce(deviceName);
      await Future<void>.delayed(interval);
    }
  }

  /// 处理收到的数据包
  void _handleDatagram(Uint8List data, String senderIp) {
    try {
      final text = utf8.decode(data);
      final json = jsonDecode(text) as Map<String, dynamic>;

      if (json['type'] != 'whisper-discover') return;

      final name = json['name'] as String? ?? '未知设备';
      final timestamp = json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;

      final peer = DiscoveredPeer(
        ip: senderIp,
        name: name,
        lastSeen: DateTime.fromMillisecondsSinceEpoch(timestamp),
      );

      _peers[peer.ip] = peer;
      onPeerDiscovered?.call(peer);
    } catch (e) {
      // 忽略无法解析的数据包
    }
  }

  /// 清理过期的联系人
  void cleanupExpired() {
    final now = DateTime.now();
    _peers.removeWhere((ip, peer) => now.difference(peer.lastSeen) > _cacheTimeout);
  }

  /// 停止并释放资源
  void dispose() {
    _isListening = false;
    _socket?.close();
  }
}
