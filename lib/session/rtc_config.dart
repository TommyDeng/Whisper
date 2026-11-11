/// WebRTC 连接配置：ICE 服务器（STUN，以及从中继取到的 TURN 临时凭据）。
///
/// DTLS-SRTP stays at the libwebrtc default. Do not set the legacy
/// `DtlsSrtpKeyAgreement: false` constraint, and do not strip `a=fingerprint`.
import 'dart:convert';
import 'dart:io';

const String defaultStunUrl = 'stun:stun.cloudflare.com:3478';

/// 解析中继 `GET /turn-credentials` 的响应，只取带凭据的 TURN 服务器。
/// 格式不对时返回空列表（调用方退回只用 STUN）。
List<Map<String, dynamic>> parseTurnServers(String body) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  if (json is! Map<String, dynamic> || json['ok'] == false) return const [];
  final list = json['iceServers'];
  if (list is! List) return const [];

  final servers = <Map<String, dynamic>>[];
  for (final item in list) {
    if (item is! Map) continue;
    final urls = item['urls'];
    final username = item['username'];
    final credential = item['credential'];
    if (urls is! List || username is! String || credential is! String) continue;
    final turnUrls = [
      for (final url in urls)
        if (url is String && (url.startsWith('turn:') || url.startsWith('turns:'))) url,
    ];
    if (turnUrls.isEmpty) continue;
    servers.add({'urls': turnUrls, 'username': username, 'credential': credential});
  }
  return servers;
}

/// [forceRelay] 为 true 时只用 TURN 中继候选（验收“强制中继”路径用）；
/// 这时如果拿不到 TURN 凭据，通话会连不上。
Future<Map<String, dynamic>> buildPeerConnectionConfig({
  String? signalingUrl,
  bool forceRelay = false,
}) async {
  final iceServers = <Map<String, dynamic>>[
    {'urls': defaultStunUrl},
  ];

  // 从中继获取 TURN 临时凭据
  if (signalingUrl != null && signalingUrl.isNotEmpty) {
    final client = HttpClient();
    try {
      final base = signalingUrl
          .replaceFirst('wss://', 'https://')
          .replaceFirst('ws://', 'http://');
      final uri = Uri.parse(base).resolve('/turn-credentials');
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 5));
      final response = await request.close().timeout(const Duration(seconds: 5));
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) iceServers.addAll(parseTurnServers(body));
    } catch (_) {
      // TURN 获取失败不阻断，回退到 STUN/直连
    } finally {
      client.close(force: true);
    }
  }

  return {
    'iceServers': iceServers,
    'sdpSemantics': 'unified-plan',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'iceCandidatePoolSize': 0,
    if (forceRelay) 'iceTransportPolicy': 'relay',
  };
}

bool configLeavesDtlsEnabled(Map<String, dynamic> config) {
  final legacy = config['DtlsSrtpKeyAgreement'];
  if (legacy == false || legacy == 'false') return false;
  return true;
}

class DtlsFingerprint {
  const DtlsFingerprint(this.algorithm, this.value);

  final String algorithm;
  final String value;

  @override
  String toString() => '$algorithm $value';
}

DtlsFingerprint? parseFingerprint(String? sdp) {
  if (sdp == null || sdp.isEmpty) return null;
  final match = RegExp(r'a=fingerprint:(\S+)\s+(\S+)', caseSensitive: false).firstMatch(sdp);
  if (match == null) return null;
  return DtlsFingerprint(match.group(1)!, match.group(2)!);
}
