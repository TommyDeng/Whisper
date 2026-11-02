/// DTLS-SRTP stays at the libwebrtc default. Do not set the legacy
/// `DtlsSrtpKeyAgreement: false` constraint, and do not strip `a=fingerprint`.
/// Application-level E2EE is intentionally absent from this spike.
Map<String, dynamic> buildPeerConnectionConfig() {
  return {
    'iceServers': [
      {'urls': 'stun:stun.cloudflare.com:3478'},
    ],
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
