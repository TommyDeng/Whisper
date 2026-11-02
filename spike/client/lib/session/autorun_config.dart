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
