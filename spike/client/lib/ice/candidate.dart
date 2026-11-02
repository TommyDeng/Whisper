import 'nic.dart';

enum PathTier { lan, zerotier, otherHost, unknownHost, mdnsHost, loopback, srflx, relay }

class ParsedCandidate {
  const ParsedCandidate({
    required this.raw,
    required this.signaledLine,
    required this.address,
    required this.type,
    required this.priority,
    required this.rewrittenPriority,
    required this.tier,
    required this.port,
  });

  final String raw;
  final String signaledLine;
  final String address;
  final String type;
  final int priority;
  final int rewrittenPriority;
  final PathTier tier;
  final int port;
}

int localPreferenceOf(int priority) => (priority >> 8) & 0xffff;

int typePreferenceOf(int priority) => (priority >> 24) & 0xff;

int withLocalPreference(int priority, int localPref) {
  return (priority & ~0x00ffff00) | ((localPref & 0xffff) << 8);
}

PathTier tierForCandidate({required String type, required String address, required List<NicInfo> nics}) {
  switch (type) {
    case 'relay':
      return PathTier.relay;
    case 'srflx':
    case 'prflx':
      return PathTier.srflx;
    case 'host':
      return switch (kindForAddress(address, nics)) {
        NicKind.lan => PathTier.lan,
        NicKind.zerotier => PathTier.zerotier,
        NicKind.loopback => PathTier.loopback,
        NicKind.mdns => PathTier.mdnsHost,
        NicKind.other => PathTier.otherHost,
        NicKind.unknownPrivate => PathTier.unknownHost,
        NicKind.unknownPublic => PathTier.otherHost,
      };
    default:
      return PathTier.otherHost;
  }
}

int desiredLocalPreference(PathTier tier) {
  return switch (tier) {
    PathTier.lan => 65535,
    PathTier.zerotier => 40960,
    PathTier.unknownHost => 32768,
    PathTier.mdnsHost => 30000,
    PathTier.otherHost => 8192,
    PathTier.loopback => 256,
    PathTier.srflx || PathTier.relay => 65535,
  };
}

bool _rewriteHost(PathTier tier) {
  return tier != PathTier.srflx && tier != PathTier.relay;
}

ParsedCandidate? parseCandidateLine(String line, List<NicInfo> nics) {
  var raw = line.trim();
  if (raw.startsWith('a=')) raw = raw.substring(2);
  if (!raw.startsWith('candidate:')) return null;
  final parts = raw.split(' ');
  if (parts.length < 8 || parts[6] != 'typ') return null;
  final priority = int.tryParse(parts[3]);
  final port = int.tryParse(parts[5]);
  if (priority == null || port == null) return null;
  final type = parts[7];
  final address = parts[4];
  final tier = tierForCandidate(type: type, address: address, nics: nics);
  final rewritten = _rewriteHost(tier) ? withLocalPreference(priority, desiredLocalPreference(tier)) : priority;
  final rewrittenParts = [...parts];
  rewrittenParts[3] = '$rewritten';
  return ParsedCandidate(
    raw: raw,
    signaledLine: rewrittenParts.join(' '),
    address: address,
    type: type,
    priority: priority,
    rewrittenPriority: rewritten,
    tier: tier,
    port: port,
  );
}

/// Reclassify against the NIC list we have now. The tier stored at parse time
/// is stale when Windows interface enumeration finishes after ICE gathering.
String signaledLineFor(ParsedCandidate parsed, List<NicInfo> nics) {
  final tier = tierForCandidate(type: parsed.type, address: parsed.address, nics: nics);
  final rewritten = _rewriteHost(tier) ? withLocalPreference(parsed.priority, desiredLocalPreference(tier)) : parsed.priority;
  final parts = parsed.raw.split(' ');
  if (parts.length < 4) return parsed.raw;
  parts[3] = '$rewritten';
  return parts.join(' ');
}
