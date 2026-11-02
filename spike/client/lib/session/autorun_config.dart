import '../ice/candidate.dart';

/// `SPIKE_ROLE` wins. Otherwise the process that is going to send
/// `SPIKE_BYTES` asks to be the offerer, so join order does not decide.
String? preferredAutorunRole({String? spikeRole, bool hasSpikeBytes = false}) {
  if (spikeRole == 'offerer' || spikeRole == 'answerer') return spikeRole;
  if (hasSpikeBytes) return 'offerer';
  return null;
}

/// Each autorun process writes its own JSON. An explicit path wins; otherwise
/// the file is named with the role assigned by the signaling room.
String autorunResultPath({String? spikeResult, required String role}) {
  if (spikeResult != null && spikeResult.isNotEmpty) return spikeResult;
  final safeRole = role == 'offerer' || role == 'answerer' ? role : 'unknown';
  return 'spike-result-$safeRole.json';
}

/// Test-only. Unset keeps the automatic LAN → ZeroTier → public order.
/// `lan`, `zerotier`, and `srflx` publish that tier and nothing else.
PathTier? parseOnlyTier(String? raw) {
  final text = raw?.trim().toLowerCase();
  if (text == null || text.isEmpty) return null;
  return switch (text) {
    'lan' => PathTier.lan,
    'zerotier' => PathTier.zerotier,
    'srflx' => PathTier.srflx,
    _ => throw FormatException('SPIKE_ONLY_TIER 只能是 lan、zerotier 或 srflx'),
  };
}

/// Seconds to leave the window open after autorun finishes. Unset or empty is 0.
int parseHoldSeconds(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return 0;
  final value = int.tryParse(text);
  if (value == null || value < 0) {
    throw FormatException('SPIKE_HOLD_SECONDS 需要是非负整数');
  }
  return value;
}
