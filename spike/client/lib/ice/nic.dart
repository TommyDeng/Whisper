import 'dart:convert';

enum NicKind { loopback, lan, zerotier, other, mdns, unknownPrivate, unknownPublic }

class NicInfo {
  const NicInfo({
    required this.name,
    required this.kind,
    required this.addresses,
    this.description,
  });

  final String name;
  final NicKind kind;
  final List<String> addresses;
  final String? description;

  String get label {
    final kindName = switch (kind) {
      NicKind.loopback => '回环',
      NicKind.lan => '局域网',
      NicKind.zerotier => 'ZeroTier',
      NicKind.other => '其他虚拟网卡',
      NicKind.mdns => 'mDNS',
      NicKind.unknownPrivate => '未识别私网',
      NicKind.unknownPublic => '公网',
    };
    final addr = addresses.isEmpty ? '无地址' : addresses.join(', ');
    final desc = description == null || description!.isEmpty ? '' : ' · $description';
    return '$name · $kindName · $addr$desc';
  }
}

NicKind classifyInterface({required String name, String? description}) {
  final n = name.trim().toLowerCase();
  final d = (description ?? '').toLowerCase();
  if (n == 'lo' || n == 'lo0' || n == 'loopback') return NicKind.loopback;
  if (d.contains('zerotier') || n.contains('zerotier') || n.startsWith('zt')) {
    return NicKind.zerotier;
  }
  if (_isVirtualOther(n, d)) return NicKind.other;
  return NicKind.lan;
}

bool _isVirtualOther(String name, String description) {
  const prefixes = [
    'docker',
    'veth',
    'br-',
    'virbr',
    'cni',
    'flannel',
    'podman',
    'tun',
    'tap',
    'wg',
    'tailscale',
    'ppp',
    'vmnet',
    'vboxnet',
    'bluetooth',
    'nft-',
    'vethernet',
  ];
  for (final prefix in prefixes) {
    if (name.startsWith(prefix)) return true;
  }
  const needles = [
    'hyper-v',
    'virtualbox',
    'vmware',
    'wintun',
    'wireguard',
    'tailscale',
    'bluetooth',
    'tap-windows',
    'vpn',
  ];
  for (final needle in needles) {
    if (description.contains(needle)) return true;
  }
  return false;
}

String normalizeIp(String address) {
  var ip = address.trim().toLowerCase();
  final zone = ip.indexOf('%');
  if (zone >= 0) ip = ip.substring(0, zone);
  if (ip.startsWith('[') && ip.endsWith(']') && ip.length > 2) {
    ip = ip.substring(1, ip.length - 1);
  }
  return ip;
}

List<int>? ipv4Octets(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return null;
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return null;
    octets.add(value);
  }
  return octets;
}

bool isLoopback(String ip) {
  final v4 = ipv4Octets(ip);
  if (v4 != null) return v4[0] == 127;
  return ip == '::1' || ip == '0:0:0:0:0:0:0:1';
}

bool isPrivateOrLinkLocal(String ip) {
  final v4 = ipv4Octets(ip);
  if (v4 != null) {
    final a = v4[0];
    final b = v4[1];
    if (a == 10 || a == 127) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 169 && b == 254) return true;
    if (a == 100 && b >= 64 && b <= 127) return true;
    return false;
  }
  if (ip.startsWith('fe80:')) return true;
  final head = ip.split(':').first;
  return head.startsWith('fc') || head.startsWith('fd');
}

NicKind kindForAddress(String address, List<NicInfo> nics) {
  final ip = normalizeIp(address);
  if (ip.isEmpty) return NicKind.unknownPublic;
  if (ip.endsWith('.local')) return NicKind.mdns;
  if (isLoopback(ip)) return NicKind.loopback;
  for (final nic in nics) {
    for (final candidate in nic.addresses) {
      if (normalizeIp(candidate) == ip) return nic.kind;
    }
  }
  if (isPrivateOrLinkLocal(ip)) return NicKind.unknownPrivate;
  return NicKind.unknownPublic;
}

bool canPreferInterfaces(List<NicInfo> nics) {
  return nics.any((nic) => nic.kind == NicKind.lan || nic.kind == NicKind.zerotier);
}

List<NicInfo> parseIpJsonAddr(String jsonText) {
  final decoded = jsonDecode(jsonText);
  if (decoded is! List) {
    throw const FormatException('ip -j addr 应该返回数组');
  }
  final nics = <NicInfo>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final name = item['ifname']?.toString() ?? '';
    if (name.isEmpty) continue;
    final oper = (item['operstate'] ?? '').toString().toUpperCase();
    if (oper == 'DOWN') continue;
    final addresses = <String>[];
    final info = item['addr_info'];
    if (info is List) {
      for (final entry in info) {
        if (entry is Map && entry['local'] != null) {
          addresses.add(entry['local'].toString());
        }
      }
    }
    nics.add(
      NicInfo(
        name: name,
        kind: classifyInterface(name: name),
        addresses: addresses,
      ),
    );
  }
  return nics;
}

List<NicInfo> parseWindowsNetJson(String jsonText) {
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map) {
    throw const FormatException('Windows 网卡 JSON 应该是对象');
  }
  final adapters = _asList(decoded['adapters']);
  final ips = _asList(decoded['ips']);
  final byAlias = <String, List<String>>{};
  for (final ip in ips) {
    if (ip is! Map) continue;
    final alias = ip['InterfaceAlias']?.toString() ?? '';
    final address = ip['IPAddress']?.toString() ?? '';
    if (alias.isEmpty || address.isEmpty) continue;
    byAlias.putIfAbsent(alias, () => []).add(address);
  }
  final nics = <NicInfo>[];
  for (final adapter in adapters) {
    if (adapter is! Map) continue;
    final name = adapter['Name']?.toString() ?? '';
    if (name.isEmpty) continue;
    final status = (adapter['Status'] ?? '').toString().toLowerCase();
    if (status.isNotEmpty && status != 'up') continue;
    final description = adapter['InterfaceDescription']?.toString();
    nics.add(
      NicInfo(
        name: name,
        description: description,
        kind: classifyInterface(name: name, description: description),
        addresses: List<String>.unmodifiable(byAlias[name] ?? const []),
      ),
    );
  }
  return nics;
}

List<dynamic> _asList(Object? value) {
  if (value is List) return value;
  if (value is Map) return [value];
  return const [];
}
