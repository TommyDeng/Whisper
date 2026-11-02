import 'nic.dart';

class PathSnapshot {
  const PathSnapshot({
    required this.label,
    required this.detail,
    this.dtlsState,
    this.dtlsCipher,
    this.srtpCipher,
    this.dtlsActive = false,
    this.localType,
    this.localAddress,
    this.remoteType,
    this.remoteAddress,
  });

  final String label;
  final String detail;
  final String? dtlsState;
  final String? dtlsCipher;
  final String? srtpCipher;
  final bool dtlsActive;
  final String? localType;
  final String? localAddress;
  final String? remoteType;
  final String? remoteAddress;

  static const waiting = PathSnapshot(label: '等待', detail: 'ICE 还没有选中候选对');
}

PathSnapshot interpretPath(List<Map<String, dynamic>> reports, List<NicInfo> nics) {
  Map<String, dynamic>? transport;
  for (final report in reports) {
    if (report['type'] == 'transport' && report['selectedCandidatePairId'] != null) {
      transport = report;
      break;
    }
  }

  Map<String, dynamic>? pair;
  final selectedId = transport?['selectedCandidatePairId']?.toString();
  if (selectedId != null) {
    pair = _byId(reports, selectedId);
  }
  pair ??= _bestNominated(reports);
  if (pair == null) {
    return PathSnapshot(
      label: PathSnapshot.waiting.label,
      detail: PathSnapshot.waiting.detail,
      dtlsState: _string(transport?['dtlsState']),
      dtlsCipher: _string(transport?['dtlsCipher']),
      srtpCipher: _string(transport?['srtpCipher']),
      dtlsActive: transport?['dtlsState'] == 'connected',
    );
  }

  final local = _byId(reports, pair['localCandidateId']?.toString());
  final remote = _byId(reports, pair['remoteCandidateId']?.toString());
  final localType = _string(local?['candidateType']) ?? _string(local?['type']);
  final remoteType = _string(remote?['candidateType']) ?? _string(remote?['type']);
  final localAddress = _string(local?['address']) ?? _string(local?['ip']);
  final remoteAddress = _string(remote?['address']) ?? _string(remote?['ip']);
  final protocol = _string(local?['protocol']) ?? _string(pair['protocol']);
  final dtlsState = _string(transport?['dtlsState']);
  final dtlsCipher = _string(transport?['dtlsCipher']);
  final srtpCipher = _string(transport?['srtpCipher']);
  final label = _labelFor(localType, localAddress, nics);
  final localPort = local?['port'];
  final remotePort = remote?['port'];
  final detail = [
    '本地 ${localType ?? '?'} ${localAddress ?? '?'}${localPort == null ? '' : ':$localPort'} ${protocol ?? ''}'.trim(),
    '对端 ${remoteType ?? '?'} ${remoteAddress ?? '?'}${remotePort == null ? '' : ':$remotePort'}',
    ?_labeled('DTLS', dtlsState),
    ?dtlsCipher,
    ?_labeled('SRTP', srtpCipher),
  ].join(' · ');

  return PathSnapshot(
    label: label,
    detail: detail,
    dtlsState: dtlsState,
    dtlsCipher: dtlsCipher,
    srtpCipher: srtpCipher,
    dtlsActive: dtlsState == 'connected',
    localType: localType,
    localAddress: localAddress,
    remoteType: remoteType,
    remoteAddress: remoteAddress,
  );
}

String? _labeled(String label, String? value) => value == null ? null : '$label $value';

String _labelFor(String? type, String? address, List<NicInfo> nics) {
  if (type == 'relay') return '中继';
  if (type == 'srflx' || type == 'prflx') return '公网 P2P';
  if (type == 'host') {
    return switch (kindForAddress(address ?? '', nics)) {
      NicKind.lan => '局域网',
      NicKind.zerotier => 'ZeroTier',
      NicKind.loopback => '本机回环',
      NicKind.mdns => 'host（mDNS，网卡未知）',
      NicKind.other => 'host（其他虚拟网卡）',
      NicKind.unknownPrivate => 'host（网卡未识别）',
      NicKind.unknownPublic => 'host（公网地址）',
    };
  }
  return '未知';
}

Map<String, dynamic>? _byId(List<Map<String, dynamic>> reports, String? id) {
  if (id == null) return null;
  for (final report in reports) {
    if (report['id']?.toString() == id) return report;
  }
  return null;
}

Map<String, dynamic>? _bestNominated(List<Map<String, dynamic>> reports) {
  Map<String, dynamic>? best;
  var bestBytes = -1.0;
  for (final report in reports) {
    if (report['type'] != 'candidate-pair') continue;
    final selected = _truthy(report['selected']);
    final nominated = _truthy(report['nominated']) && report['state'] == 'succeeded';
    if (!selected && !nominated) continue;
    final bytes = _number(report['bytesSent']) + _number(report['bytesReceived']);
    if (selected || bytes >= bestBytes) {
      best = report;
      bestBytes = bytes;
    }
  }
  return best;
}

bool _truthy(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value == 'true' || value == '1';
  return false;
}

double _number(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

String? _string(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  if (text.isEmpty || text == 'null') return null;
  return text;
}
