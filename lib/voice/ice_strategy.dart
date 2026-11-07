/// 耳语语音通话 ICE 路径策略。
///
/// 连接优先级（按架构文档 Stage 1 §9）：
///   1. 物理局域网 host 候选（最高优先级）
///   2. ZeroTier 虚拟局域网 host 候选
///   3. 公网 STUN srflx 候选
///   4. Cloudflare TURN relay 候选（兜底）
///
/// ICE 允许全部候选并行收集，通过优先级保证可用时优先选中局域网/ZeroTier。

/// ICE 路径类型
enum IcePathType {
  lan,      // 物理局域网
  zerotier, // ZeroTier 虚拟局域网
  srflx,    // 公网 P2P (STUN)
  relay,    // 云端中继 (TURN)
  unknown,  // 未知
}

/// ICE 候选信息
class IceCandidateInfo {
  const IceCandidateInfo({
    required this.type,
    required this.address,
    required this.port,
    required this.priority,
  });

  final IcePathType type;
  final String address;
  final int port;
  final int priority;

  String get label {
    switch (type) {
      case IcePathType.lan:
        return '局域网 $address:$port';
      case IcePathType.zerotier:
        return 'ZeroTier $address:$port';
      case IcePathType.srflx:
        return '公网 P2P $address:$port';
      case IcePathType.relay:
        return '中继 $address:$port';
      case IcePathType.unknown:
        return '未知 $address:$port';
    }
  }
}

/// ICE 路径策略：根据本地网卡和候选地址判断路径优先级
class IceStrategy {
  /// 本地网卡列表（用于判断哪些地址属于局域网/ZeroTier）
  final List<String> lanAddresses;
  final List<String> zerotierAddresses;

  IceStrategy({
    this.lanAddresses = const [],
    this.zerotierAddresses = const [],
  });

  /// 判断 ICE 候选的路径类型和优先级
  IceCandidateInfo classifyCandidate(String candidateLine) {
    // 解析 SDP 候选行：candidate:1 1 UDP 2122260223 192.168.1.10 10000 typ host generation 0
    final parts = candidateLine.split(' ');
    if (parts.length < 8) {
      return const IceCandidateInfo(
        type: IcePathType.unknown,
        address: '',
        port: 0,
        priority: 0,
      );
    }

    final address = parts[4];
    final port = int.tryParse(parts[5]) ?? 0;
    final typeStr = parts[7];

    final priority = _computePriority(typeStr, address);

    final iceType = _classifyType(typeStr, address);

    return IceCandidateInfo(
      type: iceType,
      address: address,
      port: port,
      priority: priority,
    );
  }

  IcePathType _classifyType(String type, String address) {
    switch (type) {
      case 'relay':
        return IcePathType.relay;
      case 'srflx':
      case 'prflx':
        return IcePathType.srflx;
      case 'host':
        if (_isZeroTier(address)) {
          return IcePathType.zerotier;
        }
        if (_isLan(address)) {
          return IcePathType.lan;
        }
        return IcePathType.unknown;
      default:
        return IcePathType.unknown;
    }
  }

  int _computePriority(String type, String address) {
    // 基于 ICE 优先级规则：type preference + local preference
    int typePref;
    switch (type) {
      case 'relay':
        typePref = 0;
      case 'srflx':
      case 'prflx':
        typePref = 1;
      case 'host':
        typePref = 2;
      default:
        typePref = 3;
    }

    int localPref;
    if (_isLan(address)) {
      localPref = 65535; // 局域网最高
    } else if (_isZeroTier(address)) {
      localPref = 40960; // ZeroTier 次高
    } else {
      localPref = 1;
    }

    return (typePref << 24) | (localPref << 8);
  }

  bool _isLan(String address) {
    return lanAddresses.any((a) => a == address) ||
        _isPrivateIp(address);
  }

  bool _isZeroTier(String address) {
    return zerotierAddresses.any((a) => a == address);
  }

  bool _isPrivateIp(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    try {
      final a = int.parse(parts[0]);
      final b = int.parse(parts[1]);
      if (a == 10) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      if (a == 169 && b == 254) return true;
    } catch (_) {
      return false;
    }
    return false;
  }

  /// 构建 RTCPeerConnection 配置：仅 STUN，不预配置 TURN（由信令按需签发）
  static Map<String, dynamic> buildPcConfig({
    List<Map<String, dynamic>> iceServers = const [],
  }) {
    return {
      'iceServers': [
        {'urls': 'stun:stun.cloudflare.com:3478'},
        ...iceServers,
      ],
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'iceCandidatePoolSize': 0,
    };
  }
}
