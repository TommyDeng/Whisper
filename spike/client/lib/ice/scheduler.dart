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
    required this._nics,
    this.fallback = const Duration(seconds: 5),
    this.maxGatherWait = const Duration(seconds: 4),
    this.nicMapWait = const Duration(seconds: 15),
    this._nicMapReady = false,
    this.onlyTier,
  });

  final Duration fallback;
  final Duration maxGatherWait;
  final Duration nicMapWait;
  final PathTier? onlyTier;
  final List<NicInfo> _nics;

  final List<OutgoingCandidate> _items = [];
  DateTime? _firstAt;
  DateTime? _preferredAt;
  ReleasePhase _phase = ReleasePhase.holding;
  PathTier? _preferred;
  BypassReason _bypassReason = BypassReason.none;
  bool _gatheringDone = false;
  bool _sealed = false;
  bool _nicMapReady;
  bool _sawMdns = false;
  bool _holdingForNics = false;

  ReleasePhase get phase => _phase;
  BypassReason get bypassReason => _bypassReason;
  PathTier? get preferredTier => _preferred;

  /// The Windows probe can finish after the first candidates arrive.
  /// Call this when enumeration succeeds or fails so we stop waiting.
  void noteNicMapReady() {
    _nicMapReady = true;
  }

  PathTier tierOf(OutgoingCandidate item) {
    return tierForCandidate(type: item.parsed.type, address: item.parsed.address, nics: _nics);
  }

  String lineToSignal(OutgoingCandidate item) {
    return signaledLineFor(item.parsed, _nics);
  }

  void add(
    ParsedCandidate candidate, {
    String? sdpMid,
    int? sdpMLineIndex,
    required DateTime now,
  }) {
    if (tierForCandidate(type: candidate.type, address: candidate.address, nics: _nics) == PathTier.mdnsHost) {
      _sawMdns = true;
    }
    _firstAt ??= now;
    _items.add(OutgoingCandidate(candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex));
  }

  void markGatheringComplete() {
    _gatheringDone = true;
  }

  void seal() {
    if (onlyTier != null) {
      _sealed = true;
      _phase = ReleasePhase.sealed;
      return;
    }
    _refreshGate(DateTime.now());
    if (_holdingForNics) return;
    if (_bypassReason == BypassReason.none && _phase != ReleasePhase.all) {
      _sealed = true;
      _phase = ReleasePhase.sealed;
    }
  }

  List<OutgoingCandidate> drain(DateTime now) {
    if (_sealed) return const [];
    if (onlyTier != null) return _drainOnlyTier(now);
    _refreshGate(now);
    if (_holdingForNics) return const [];
    if (_bypassReason != BypassReason.none) {
      _phase = ReleasePhase.all;
      return _take((item) => true);
    }
    _advance(now);
    if (_phase == ReleasePhase.all) return _take((item) => true);
    final preferred = _preferred;
    if (_phase == ReleasePhase.preferred && preferred != null) {
      return _take((item) => tierOf(item) == preferred);
    }
    return const [];
  }

  void _refreshGate(DateTime now) {
    if (_sawMdns) {
      _holdingForNics = false;
      _bypassReason = BypassReason.mdns;
      return;
    }
    if (canPreferInterfaces(_nics)) {
      _holdingForNics = false;
      _bypassReason = BypassReason.none;
      return;
    }
    final started = _firstAt ?? now;
    final stillWaiting = !_nicMapReady && now.difference(started) < nicMapWait;
    if (stillWaiting) {
      _holdingForNics = true;
      _bypassReason = BypassReason.none;
      _phase = ReleasePhase.holding;
      return;
    }
    _holdingForNics = false;
    _bypassReason = BypassReason.noNicMap;
  }

  List<OutgoingCandidate> _drainOnlyTier(DateTime now) {
    final tier = onlyTier!;
    final needsMap = tier == PathTier.lan || tier == PathTier.zerotier;
    if (needsMap && !canPreferInterfaces(_nics)) {
      final started = _firstAt ?? now;
      if (!_nicMapReady && now.difference(started) < nicMapWait) {
        _holdingForNics = true;
        _bypassReason = BypassReason.none;
        _phase = ReleasePhase.holding;
        return const [];
      }
    }
    _holdingForNics = false;
    _bypassReason = BypassReason.none;
    _preferred = tier;
    _phase = ReleasePhase.preferred;
    return _take((item) => tierOf(item) == tier);
  }

  String _onlyTierLabel() {
    return switch (onlyTier) {
      PathTier.lan => '局域网',
      PathTier.zerotier => 'ZeroTier',
      PathTier.srflx => '公网 srflx',
      _ => onlyTier?.name ?? '',
    };
  }

  String describe() {
    if (onlyTier != null) {
      final state = _holdingForNics
          ? '正在识别网卡，之后只发布${_onlyTierLabel()}'
          : '测试覆盖：只发布${_onlyTierLabel()}，不回退${_sealed ? '，已连通' : ''}';
      return state;
    }
    if (_holdingForNics) return '正在识别网卡，先不发布候选';
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
    return _items.any((item) => !item.signaled && tierOf(item) == tier);
  }

  bool _hasAny(PathTier tier) {
    return _items.any((item) => tierOf(item) == tier);
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
