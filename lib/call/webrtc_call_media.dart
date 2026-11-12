/// [CallMedia] 的 WebRTC 实现：一个 RTCPeerConnection 加麦克风，只有音频。
///
/// 媒体由 WebRTC 自带的 DTLS-SRTP 加密；DTLS 指纹在 SDP 里，而 SDP 走端到端加密的信令，
/// 所以中继和 TURN 服务器都无法冒充对方。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../voice/ice_strategy.dart';
import 'call_audio.dart';
import 'call_service.dart';
import 'call_signal.dart';

/// 取 ICE 服务器配置（STUN，以及拿得到的话 TURN 临时凭据）。
typedef IceConfigLoader = Future<Map<String, dynamic>> Function();

class WebRtcCallMedia implements CallMedia {
  WebRtcCallMedia({required this.loadConfig});

  final IceConfigLoader loadConfig;

  final _candidates = StreamController<CallCandidate>();
  final _states = StreamController<CallMediaState>();
  final _paths = StreamController<IcePathType>.broadcast();
  final _levels = StreamController<double>.broadcast();
  final _rendererChanges = StreamController<RTCVideoRenderer?>.broadcast();

  RTCPeerConnection? _pc;
  MediaStream? _local;
  final _remoteRenderer = RTCVideoRenderer();
  bool _remoteRendererReady = false;
  Timer? _levelTimer;
  bool _muted = false;
  bool _closed = false;
  bool _connected = false;
  IcePathType? _path;

  @override
  Stream<CallCandidate> get candidates => _candidates.stream;

  @override
  Stream<CallMediaState> get states => _states.stream;

  /// 当前走的是哪条路径；连上之前为 null。
  IcePathType? get path => _path;

  /// 路径变化（广播流）。
  Stream<IcePathType> get paths => _paths.stream;

  /// 本端麦克风电平（0.0–1.0），通话过程中周期性更新。
  Stream<double> get localAudioLevels => _levels.stream;

  /// 用于播放远端音频的隐藏渲染器；初始化完成前为 null。
  RTCVideoRenderer? get remoteRenderer => _remoteRendererReady ? _remoteRenderer : null;

  /// 远端渲染器就绪或被释放。
  Stream<RTCVideoRenderer?> get remoteRendererChanges => _rendererChanges.stream;

  @override
  Future<String> createOffer() async {
    final pc = await _open();
    final offer = await pc.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': false});
    await pc.setLocalDescription(offer);
    return offer.sdp!;
  }

  @override
  Future<String> acceptOffer(String sdp) async {
    final pc = await _open();
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    return answer.sdp!;
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    await _pc?.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  @override
  Future<void> addCandidate(CallCandidate candidate) async {
    try {
      await _pc?.addCandidate(
        RTCIceCandidate(candidate.candidate, candidate.sdpMid, candidate.sdpMLineIndex),
      );
    } catch (_) {
      // 个别候选加不进去不影响其它候选
    }
  }

  @override
  void setMuted(bool muted) {
    _muted = muted;
    for (final track in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _levelTimer?.cancel();
    _levelTimer = null;
    final pc = _pc;
    final local = _local;
    _pc = null;
    _local = null;
    try {
      for (final track in local?.getTracks() ?? const <MediaStreamTrack>[]) {
        await track.stop();
      }
      await local?.dispose();
    } catch (_) {}
    try {
      await pc?.close();
    } catch (_) {}
    try {
      _remoteRenderer.srcObject = null;
      if (_remoteRendererReady) {
        await _remoteRenderer.dispose();
      }
    } catch (_) {}
    _remoteRendererReady = false;
    if (!_rendererChanges.isClosed) _rendererChanges.add(null);
    await _candidates.close();
    await _states.close();
    await _paths.close();
    await _levels.close();
    await _rendererChanges.close();
  }

  Future<RTCPeerConnection> _open() async {
    if (_closed) throw StateError('已关闭');
    final local = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': false,
    });
    if (_closed) {
      await local.dispose();
      throw StateError('已关闭');
    }
    _local = local;
    setMuted(_muted);
    await _selectDefaultPlayout();
    await _ensureRemoteRenderer();

    final pc = await createPeerConnection(await loadConfig());
    if (_closed) {
      await pc.close();
      throw StateError('已关闭');
    }
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      final line = candidate.candidate;
      if (_closed || line == null || line.isEmpty) return;
      _candidates.add(CallCandidate(line, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex));
    };
    pc.onConnectionState = (state) {
      if (_closed) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          if (!_connected) {
            _connected = true;
            _states.add(CallMediaState.connected);
          }
          unawaited(_refreshPath());
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _states.add(CallMediaState.failed);
        default:
          // disconnected 可能自己恢复，恢复不了会变成 failed
          break;
      }
    };
    pc.onIceConnectionState = (state) {
      // 网络切换后选中的候选对可能变了
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        unawaited(_refreshPath());
      }
    };
    pc.onTrack = (event) {
      if (event.track.kind != 'audio') return;
      event.track.enabled = true;
      if (event.streams.isNotEmpty && _remoteRendererReady) {
        _remoteRenderer.srcObject = event.streams[0];
      }
    };

    for (final track in local.getAudioTracks()) {
      await pc.addTrack(track, local);
    }
    _startLevelTimer();
    return pc;
  }

  Future<void> _ensureRemoteRenderer() async {
    if (_remoteRendererReady || _closed) return;
    try {
      await _remoteRenderer.initialize();
      if (_closed) {
        await _remoteRenderer.dispose();
        return;
      }
      _remoteRendererReady = true;
      _rendererChanges.add(_remoteRenderer);
    } catch (_) {
      // 渲染器初始化失败时仍继续通话，只是可能播不出远端声音
    }
  }

  Future<void> _selectDefaultPlayout() async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      final id = pickDefaultPlayoutDeviceId([
        for (final device in devices)
          AudioDeviceOption(
            deviceId: device.deviceId,
            label: device.label,
            kind: device.kind ?? '',
          ),
      ]);
      if (id == null || _closed) return;
      await Helper.selectAudioOutput(id);
    } catch (_) {
      // 本机或平台不支持选择输出设备时保持系统默认
    }
  }

  void _startLevelTimer() {
    _levelTimer?.cancel();
    _levelTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      unawaited(_refreshLocalAudioLevel());
    });
  }

  Future<void> _refreshLocalAudioLevel() async {
    try {
      final pc = _pc;
      if (pc == null || _closed) return;
      final level = localAudioLevelFromStats(await pc.getStats());
      if (level == null || _closed || _levels.isClosed) return;
      _levels.add(_muted ? 0 : level);
    } catch (_) {
      // 拿不到统计就不更新电平
    }
  }

  /// 从统计信息里找出选中的候选对，判断走的是哪条路径。
  Future<void> _refreshPath() async {
    try {
      final pc = _pc;
      if (pc == null) return;
      final reports = await pc.getStats();
      final byId = {for (final report in reports) report.id: report};

      String? pairId;
      for (final report in reports) {
        if (report.type == 'transport') {
          final selected = report.values['selectedCandidatePairId'];
          if (selected is String && selected.isNotEmpty) pairId = selected;
        }
      }
      StatsReport? pair = pairId == null ? null : byId[pairId];
      pair ??= reports.cast<StatsReport?>().firstWhere(
            (report) =>
                report!.type == 'candidate-pair' &&
                report.values['state'] == 'succeeded' &&
                report.values['nominated'] == true,
            orElse: () => null,
          );
      if (pair == null) return;

      final local = byId[pair.values['localCandidateId']];
      final remote = byId[pair.values['remoteCandidateId']];
      if (local == null || remote == null) return;
      final path = classifyPath(
        localType: '${local.values['candidateType']}',
        remoteType: '${remote.values['candidateType']}',
        localAddress: '${local.values['address'] ?? local.values['ip'] ?? ''}',
        zeroTierAddresses: await zeroTierAddresses(),
      );
      if (_closed || path == _path) return;
      _path = path;
      _paths.add(path);
    } catch (_) {
      // 拿不到统计信息就不显示路径
    }
  }
}

/// 根据选中候选对两端的类型和本端地址判断路径。
IcePathType classifyPath({
  required String localType,
  required String remoteType,
  required String localAddress,
  required Set<String> zeroTierAddresses,
}) {
  if (localType == 'relay' || remoteType == 'relay') return IcePathType.relay;
  if (zeroTierAddresses.contains(localAddress)) return IcePathType.zerotier;
  if (localType == 'host' && remoteType == 'host') return IcePathType.lan;
  if (const {'host', 'srflx', 'prflx'}.contains(localType)) return IcePathType.srflx;
  return IcePathType.unknown;
}

/// 本机 ZeroTier 网卡上的地址（Linux 上网卡名以 zt 开头，Windows 上名字里带 ZeroTier）。
Future<Set<String>> zeroTierAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(includeLinkLocal: true);
    return {
      for (final interface in interfaces)
        if (isZeroTierInterface(interface.name))
          for (final address in interface.addresses) address.address,
    };
  } catch (_) {
    return const {};
  }
}

bool isZeroTierInterface(String name) {
  final lower = name.toLowerCase();
  return lower.startsWith('zt') || lower.contains('zerotier');
}
