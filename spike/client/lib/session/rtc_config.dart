/// DTLS-SRTP stays at the libwebrtc default. Do not set the legacy
/// `DtlsSrtpKeyAgreement: false` constraint, and do not strip `a=fingerprint`.
/// Application-level E2EE is intentionally absent from this spike.
import 'dart:convert';
import 'dart:io';

Future<Map<String, dynamic>> buildPeerConnectionConfig({String? signalingUrl}) async {
  final iceServers = <Map<String, dynamic>>[
    {'urls': 'stun:stun.cloudflare.com:3478'},
  ];

  // 从信令服务器获取 TURN 临时凭据
  if (signalingUrl != null && signalingUrl.isNotEmpty) {
    try {
      final base = signalingUrl
          .replaceFirst('wss://', 'https://')
          .replaceFirst('ws://', 'http://');
      final uri = Uri.parse('$base/turn-credentials');
      final client = HttpClient();
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 5));
      final response = await request.close().timeout(const Duration(seconds: 5));
      final body = await response.transform(utf8.decoder).join();
      client.close();
      if (response.statusCode == 200) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        if (data['ok'] != false && data['urls'] != null) {
          iceServers.add({
            'urls': List<String>.from(data['urls']),
            'username': data['username'] ?? '',
            'credential': data['credential'] ?? '',
          });
        }
      }
    } catch (error) {
      // TURN 获取失败不阻断，回退到 STUN/直连
      print('TURN credentials unavailable: $error');
    }
  }

  return {
    'iceServers': iceServers,
    'sdpSemantics': 'unified-plan',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'iceCandidatePoolSize': 0,
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
