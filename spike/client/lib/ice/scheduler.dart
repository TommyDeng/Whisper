import 'candidate.dart';
import 'nic.dart';

enum ReleasePhase { holding, preferred, all, sealed }

enum BypassReason { none, mdns, noNicMap }

class OutgoingCandidate {
  OutgoingCandidate(this.parsed, {this.sdpMid, this.sdpMLineIndex});

  final ParsedCandidate parsed;
  final String? sdpMid;
  final int? sdpMLineIndex;
  bool signaled = false;
}

/// flutter_webrtc does not let us change the local ICE agent's priority.
/// This scheduler rewrites the priority we *signal* and, more importantly,
/// withholds less-preferred candidates until a fallback timer. Peers only
/// check paths whose candidates they have been told about.
class CandidateScheduler {
  CandidateScheduler({
    required List<NicInfo> nics,
    this.fallback = const Duration(seconds: 5),
    this.maxGatherWait = const Duration(seconds: 4),
  }) : _bypassReason = canPreferInterfaces(nics) ? BypassReason.none : BypassReason.noNicMap;

  final Duration fallback;
  final Duration maxGatherWait;

  final List<OutgoingCandidate> _items = [];
  DateTime? _firstAt;
  DateTime? _preferredAt;
  ReleasePhase _phase = ReleasePhase.holding;
  PathTier? _preferred;
  BypassReason _bypassReason;
  bool _gatheringDone = false;
  bool _sealed = false;

  ReleasePhase get phase => _phase;
  BypassReason get bypassReason => _bypassReason;
  PathTier? get preferredTier => _preferred;

  void add(
    ParsedCandidate candidate, {
    String? sdpMid,
    int? sdpMLineIndex,
    required DateTime now,
  }) {
    if (candidate.tier == PathTier.mdnsHost && _bypassReason == BypassReason.none) {
      _bypassReason = BypassReason.mdns;
    }
    _firstAt ??= now;
    _items.add(OutgoingCandidate(candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex));
  }

  void markGatheringComplete() {
    _gatheringDone = true;
  }

  void seal() {
    if (_bypassReason == BypassReason.none && _phase != ReleasePhase.all) {
      _sealed = true;
      _phase = ReleasePhase.sealed;
    }
  }

  List<OutgoingCandidate> drain(DateTime now) {
    if (_sealed) return const [];
    if (_bypassReason != BypassReason.none) {
      _phase = ReleasePhase.all;
      return _take((item) => true);
    }
    _advance(now);
    if (_phase == ReleasePhase.all) return _take((item) => true);
    final preferred = _preferred;
    if (_phase == ReleasePhase.preferred && preferred != null) {
      return _take((item) => item.parsed.tier == preferred);
    }
    return const [];
  }

  String describe() {
    switch (_bypassReason) {
      case BypassReason.mdns:
        return '宿主候选是 mDNS（*.local），无法区分局域网和 ZeroTier，已全部发布';
      case BypassReason.noNicMap:
        return '没能识别局域网或 ZeroTier 网卡，已全部发布';
      case BypassReason.none:
        break;
    }
    return switch (_phase) {
      ReleasePhase.holding => '正在收集候选，先不发给对端',
      ReleasePhase.preferred => _preferred == PathTier.lan ? '只发布局域网 host 候选' : '只发布 ZeroTier host 候选',
      ReleasePhase.all => '已放开其余候选（公网、回环、未识别网卡）',
      ReleasePhase.sealed => '已连通，不再发布更低优先级候选',
    };
  }

  void _advance(DateTime now) {
    if (_phase == ReleasePhase.holding) {
      if (_hasUnsent(PathTier.lan)) {
        _enter(PathTier.lan, now);
        return;
      }
      final waited = _firstAt == null ? Duration.zero : now.difference(_firstAt!);
      final decide = _gatheringDone || waited >= maxGatherWait;
      if (!decide) return;
      if (_hasUnsent(PathTier.zerotier) || _hasAny(PathTier.zerotier)) {
        _enter(PathTier.zerotier, now);
        return;
      }
      _phase = ReleasePhase.all;
      return;
    }
    if (_phase == ReleasePhase.preferred && _preferred == PathTier.zerotier && _hasUnsent(PathTier.lan)) {
      _enter(PathTier.lan, now);
      return;
    }
    if (_phase == ReleasePhase.preferred && _preferredAt != null && now.difference(_preferredAt!) >= fallback) {
      _phase = ReleasePhase.all;
    }
  }

  void _enter(PathTier tier, DateTime now) {
    _phase = ReleasePhase.preferred;
    _preferred = tier;
    _preferredAt = now;
  }

  bool _hasUnsent(PathTier tier) {
    return _items.any((item) => !item.signaled && item.parsed.tier == tier);
  }

  bool _hasAny(PathTier tier) {
    return _items.any((item) => item.parsed.tier == tier);
  }

  List<OutgoingCandidate> _take(bool Function(OutgoingCandidate item) ready) {
    final out = <OutgoingCandidate>[];
    for (final item in _items) {
      if (item.signaled || !ready(item)) continue;
      item.signaled = true;
      out.add(item);
    }
    return out;
  }
}
