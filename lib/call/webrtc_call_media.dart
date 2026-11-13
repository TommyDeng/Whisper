/// [CallMedia] 的 WebRTC 实现：一个 RTCPeerConnection 加麦克风，只有音频。
///
/// 媒体由 WebRTC 自带的 DTLS-SRTP 加密；DTLS 指纹在 SDP 里，而 SDP 走端到端加密的信令，
/// 所以中继和 TURN 服务器都无法冒充对方。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../desktop/window_attention.dart';
import '../voice/ice_strategy.dart';
import 'call_audio.dart';
import 'call_service.dart';
import 'call_signal.dart';

/// 取 ICE 服务器配置（STUN，以及拿得到的话 TURN 临时凭据）。
typedef IceConfigLoader = Future<Map<String, dynamic>> Function();

/// 系统当前的默认输出 / 输入设备 id；拿不到的为 null。
typedef SystemAudioDefaults = ({String? output, String? input});

/// 向原生层问系统默认设备。只有 Windows 需要：那里枚举出来的设备既没有
/// 带 default 的名字，顺序也和默认设备无关。
Future<SystemAudioDefaults> loadSystemAudioDefaults() async {
  if (!Platform.isWindows) return (output: null, input: null);
  try {
    final result = await kDesktopChannel.invokeMapMethod<String, String>(
      'defaultAudioDevices',
    );
    return (output: result?['output'], input: result?['input']);
  } catch (_) {
    return (output: null, input: null);
  }
}

class WebRtcCallMedia implements CallMedia {
  WebRtcCallMedia({required this.loadConfig});

  final IceConfigLoader loadConfig;

  final _candidates = StreamController<CallCandidate>();
  final _states = StreamController<CallMediaState>();
  final _paths = StreamController<IcePathType>.broadcast();
  final _levels = StreamController<double>.broadcast();
  final _stats = StreamController<CallAudioStats>.broadcast();
  final _rendererChanges = StreamController<RTCVideoRenderer?>.broadcast();
  final _localRendererChanges = StreamController<RTCVideoRenderer?>.broadcast();

  RTCPeerConnection? _pc;
  MediaStream? _local;
  final _remoteRenderer = RTCVideoRenderer();
  final _localRenderer = RTCVideoRenderer();
  bool _remoteRendererReady = false;
  bool _localRendererReady = false;
  Timer? _levelTimer;
  var _levelTicks = 0;

  /// 电平定时器每 200ms 一拍，每 5 拍（1 秒）核对一次通话路径。
  static const _pathCheckEveryTicks = 5;
  bool _muted = false;
  bool _closed = false;
  IcePathType? _path;

  /// 实际选中的播放设备名，显示在通话诊断里；没有指定设备时是「系统默认」。
  String? _playoutLabel;

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

  /// 本端发送 / 远端接收的电平和字节数，供通话条诊断。
  Stream<CallAudioStats> get audioStats => _stats.stream;

  /// 用于播放远端音频的隐藏渲染器；初始化完成前为 null。
  RTCVideoRenderer? get remoteRenderer =>
      _remoteRendererReady ? _remoteRenderer : null;

  /// 远端渲染器就绪或被释放。
  Stream<RTCVideoRenderer?> get remoteRendererChanges =>
      _rendererChanges.stream;

  /// 挂上本端麦克风流的隐藏渲染器。部分平台要有渲染器才会真正开始采集。
  RTCVideoRenderer? get localRenderer =>
      _localRendererReady ? _localRenderer : null;

  Stream<RTCVideoRenderer?> get localRendererChanges =>
      _localRendererChanges.stream;

  @override
  Future<String> createOffer() async {
    final pc = await _open();
    final offer = await pc.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
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
  Future<String> restartOffer() async {
    final pc = _pc;
    if (pc == null || _closed) throw StateError('已关闭');
    // 换一套 ICE 凭据并重新收集候选：原来走的网卡没了（例如 ZeroTier 被关掉）时，
    // 这样才能换到还通的路径上。
    await pc.restartIce();
    final offer = await pc.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    await pc.setLocalDescription(offer);
    return offer.sdp!;
  }

  @override
  Future<String> acceptRestartOffer(String sdp) async {
    final pc = _pc;
    if (pc == null || _closed) throw StateError('已关闭');
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    return answer.sdp!;
  }

  @override
  Future<void> addCandidate(CallCandidate candidate) async {
    try {
      await _pc?.addCandidate(
        RTCIceCandidate(
          candidate.candidate,
          candidate.sdpMid,
          candidate.sdpMLineIndex,
        ),
      );
    } catch (_) {
      // 个别候选加不进去不影响其它候选
    }
  }

  @override
  void setMuted(bool muted) {
    _muted = muted;
    for (final track
        in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
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
    try {
      _localRenderer.srcObject = null;
      if (_localRendererReady) {
        await _localRenderer.dispose();
      }
    } catch (_) {}
    _remoteRendererReady = false;
    _localRendererReady = false;
    if (!_rendererChanges.isClosed) _rendererChanges.add(null);
    if (!_localRendererChanges.isClosed) _localRendererChanges.add(null);
    await _candidates.close();
    await _states.close();
    await _paths.close();
    await _levels.close();
    await _stats.close();
    await _rendererChanges.close();
    await _localRendererChanges.close();
  }

  Future<RTCPeerConnection> _open() async {
    if (_closed) throw StateError('已关闭');
    // 不要调用 Helper.ensureAudioSession()：它只有 iOS 实现，桌面端的原生层收到
    // 没有参数的未知方法会抛 std::bad_variant_access，整个进程直接退出。
    final constraints = await _audioConstraints();
    final local = await navigator.mediaDevices.getUserMedia({
      'audio': constraints,
      'video': false,
    });
    if (_closed) {
      await local.dispose();
      throw StateError('已关闭');
    }
    _local = local;
    setMuted(_muted);
    await _selectDefaultDevices();
    await _ensureRemoteRenderer();
    await _ensureLocalRenderer();
    if (_localRendererReady) {
      _localRenderer.srcObject = local;
    }

    final pc = await createPeerConnection(await loadConfig());
    if (_closed) {
      await pc.close();
      throw StateError('已关闭');
    }
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      final line = candidate.candidate;
      if (_closed || line == null || line.isEmpty) return;
      _candidates.add(
        CallCandidate(
          line,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );
    };
    pc.onConnectionState = (state) {
      if (_closed) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          // 断开后重新连上也要报：通话服务靠它结束重连。
          _states.add(CallMediaState.connected);
          unawaited(_refreshPath());
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          // 可能自己恢复；恢复不了时通话服务会做 ICE 重启。
          _states.add(CallMediaState.disconnected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _states.add(CallMediaState.failed);
        default:
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
      unawaited(_attachRemoteTrack(event));
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

  Future<Map<String, dynamic>> _audioConstraints() async {
    final audio = <String, dynamic>{
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
    };
    try {
      final options = await _deviceOptions();
      final defaults = await loadSystemAudioDefaults();
      final inputId = _pickRecording(options, defaults);
      final outputId = _pickPlayout(options, defaults);
      // flutter_webrtc 桌面端：sourceId 选麦克风，deviceId 选扬声器（在 GetUserAudio 里调用 SetPlayoutDevice）。
      if (inputId != null) audio['sourceId'] = inputId;
      if (outputId != null) audio['deviceId'] = outputId;
    } catch (_) {
      // 枚举失败就走系统默认
    }
    return audio;
  }

  Future<List<AudioDeviceOption>> _deviceOptions() async {
    final devices = await navigator.mediaDevices.enumerateDevices();
    return [
      for (final device in devices)
        AudioDeviceOption(
          deviceId: device.deviceId,
          label: device.label,
          kind: device.kind ?? '',
        ),
    ];
  }

  // Windows 上找不到系统默认设备时宁可不指定，也不取枚举到的第一个：
  // 第一个常常是显示器之类的设备，声音会被送到用户没在听的地方。
  String? _pickPlayout(
    List<AudioDeviceOption> options,
    SystemAudioDefaults defaults,
  ) => pickDefaultPlayoutDeviceId(
    options,
    systemDefaultId: defaults.output,
    fallbackToFirst: !Platform.isWindows,
  );

  String? _pickRecording(
    List<AudioDeviceOption> options,
    SystemAudioDefaults defaults,
  ) => pickDefaultRecordingDeviceId(
    options,
    systemDefaultId: defaults.input,
    fallbackToFirst: !Platform.isWindows,
  );

  Future<void> _selectDefaultDevices() async {
    await _selectDefaultRecording();
    await _selectDefaultPlayout();
  }

  Future<void> _selectDefaultRecording() async {
    try {
      final id = _pickRecording(
        await _deviceOptions(),
        await loadSystemAudioDefaults(),
      );
      if (id == null || _closed) return;
      await Helper.selectAudioInput(id);
    } catch (_) {
      // 平台不支持或枚举为空时保持系统默认
    }
  }

  Future<void> _selectDefaultPlayout() async {
    try {
      final options = await _deviceOptions();
      final id = _pickPlayout(options, await loadSystemAudioDefaults());
      if (_closed) return;
      if (id == null) {
        _playoutLabel = '系统默认';
        return;
      }
      await Helper.selectAudioOutput(id);
      _playoutLabel = deviceLabelFor(options, id);
    } catch (_) {
      // 本机或平台不支持选择输出设备时保持系统默认
    }
  }

  Future<void> _attachRemoteTrack(RTCTrackEvent event) async {
    await _selectDefaultPlayout();
    if (_closed || !_remoteRendererReady) return;
    try {
      if (event.streams.isNotEmpty) {
        _remoteRenderer.srcObject = event.streams[0];
        return;
      }
      // Unified Plan 偶发 streams 为空：自己建一条流把 track 挂上去，否则 Windows 可能完全不播。
      final stream = await createLocalMediaStream('remote-audio');
      if (_closed) return;
      await stream.addTrack(event.track);
      _remoteRenderer.srcObject = stream;
    } catch (_) {
      // 挂不上渲染器时仍继续通话
    }
  }

  Future<void> _ensureLocalRenderer() async {
    if (_localRendererReady || _closed) return;
    try {
      await _localRenderer.initialize();
      if (_closed) {
        await _localRenderer.dispose();
        return;
      }
      _localRendererReady = true;
      _localRendererChanges.add(_localRenderer);
    } catch (_) {
      // 没有本端渲染器时仍尝试采集
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
      final reports = await pc.getStats();
      final stats = callAudioStatsFromReports(reports);
      if (_closed || _levels.isClosed) return;
      // 选中的候选对可能在连接状态不变的情况下换掉（一条路断了，ICE 直接改用
      // 另一条还通着的），这时没有任何事件。所以顺着这份统计每秒核对一次路径。
      if (++_levelTicks % _pathCheckEveryTicks == 0) {
        unawaited(_refreshPath(reports));
      }
      final level = _muted ? 0.0 : (stats.localLevel ?? 0);
      _levels.add(level);
      if (!_stats.isClosed) {
        _stats.add(
          CallAudioStats(
            localLevel: _muted ? 0 : stats.localLevel,
            bytesSent: stats.bytesSent,
            localEnergy: stats.localEnergy,
            remoteLevel: stats.remoteLevel,
            bytesReceived: stats.bytesReceived,
            remoteEnergy: stats.remoteEnergy,
            playoutDevice: _playoutLabel,
          ),
        );
      }
    } catch (_) {
      // 拿不到统计就不更新电平
    }
  }

  /// 从统计信息里找出选中的候选对，判断走的是哪条路径。
  Future<void> _refreshPath([List<StatsReport>? known]) async {
    try {
      final pc = _pc;
      if (pc == null) return;
      final reports = known ?? await pc.getStats();
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
  if (const {'host', 'srflx', 'prflx'}.contains(localType)) {
    return IcePathType.srflx;
  }
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
