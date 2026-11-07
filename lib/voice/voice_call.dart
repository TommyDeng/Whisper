/// 耳语语音通话管理器。
///
/// 负责：
/// - 创建和管理 RTCPeerConnection（DTLS-SRTP）
/// - 音频轨道采集（麦克风）和播放
/// - ICE 候选收集与优先级（局域网优先）
/// - 信令消息处理（offer/answer/candidate/bye）
/// - 通话状态监控和路径显示

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import './ice_strategy.dart';
export './ice_strategy.dart';

/// 语音通话状态
enum CallState {
  idle,
  calling,
  connected,
  disconnected,
  failed,
}

/// 语音通话管理器
class VoiceCall {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RTCDataChannel? _dataChannel;

  final IceStrategy iceStrategy;

  void Function(String candidate, String? sdpMid, int? sdpMLineIndex)
      onRemoteCandidate;
  void Function(String sdp) onRemoteOffer;
  void Function(String sdp) onRemoteAnswer;
  void Function(CallState state) onStateChanged;
  void Function(IceCandidateInfo path) onPathChanged;
  void Function() onRemoteHangup;

  CallState _state = CallState.idle;
  String? _currentPath;

  CallState get state => _state;
  String? get currentPath => _currentPath;
  bool get isLocalMicMuted =>
      _localStream?.getAudioTracks().isNotEmpty == true &&
      !_localStream!.getAudioTracks().first.enabled;

  VoiceCall({
    required this.iceStrategy,
    required this.onRemoteCandidate,
    required this.onRemoteOffer,
    required this.onRemoteAnswer,
    required this.onStateChanged,
    required this.onPathChanged,
    required this.onRemoteHangup,
  });

  /// 初始化本地音频流（麦克风）
  Future<void> initLocalAudio() async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
      _state = CallState.idle;
      onStateChanged(_state);
    } catch (e) {
      _state = CallState.failed;
      onStateChanged(_state);
      rethrow;
    }
  }

  /// 创建 PeerConnection（offerer 侧）
  Future<void> createOffer() async {
    if (_pc != null) return;

    _pc = await createPeerConnection(IceStrategy.buildPcConfig());
    _setupPcListeners();

    await _addLocalAudioTrack();

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    onRemoteOffer(offer.sdp!);
    _state = CallState.calling;
    onStateChanged(_state);
  }

  /// 创建 PeerConnection（answerer 侧，接收 offer 后）
  Future<void> createAnswer(String remoteSdp) async {
    if (_pc != null) return;

    _pc = await createPeerConnection(IceStrategy.buildPcConfig());
    _setupPcListeners();

    await _addLocalAudioTrack();

    await _pc!.setRemoteDescription(RTCSessionDescription(remoteSdp, 'offer'));

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    onRemoteAnswer(answer.sdp!);
    _state = CallState.connected;
    onStateChanged(_state);
  }

  /// 接收远端 offer（answerer 侧）
  Future<void> setRemoteOffer(String sdp) async {
    if (_pc == null) {
      _pc = await createPeerConnection(IceStrategy.buildPcConfig());
      _setupPcListeners();
      await _addLocalAudioTrack();
    }

    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    onRemoteAnswer(answer.sdp!);
  }

  /// 接收远端 answer（offerer 侧）
  Future<void> setRemoteAnswer(String sdp) async {
    if (_pc == null) return;
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _state = CallState.connected;
    onStateChanged(_state);
  }

  /// 添加远端 ICE 候选
  Future<void> addRemoteCandidate(
    String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  ) async {
    if (_pc == null) return;
    final ice = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
    await _pc!.addCandidate(ice);
  }

  /// 挂断
  Future<void> hangup() async {
    await _pc?.close();
    _pc = null;
    await _localStream?.dispose();
    _localStream = null;
    _remoteStream = null;
    _dataChannel = null;
    _state = CallState.disconnected;
    onStateChanged(_state);
  }

  /// 静音/取消静音
  Future<void> toggleMute() async {
    final tracks = _localStream?.getAudioTracks() ?? [];
    if (tracks.isNotEmpty) {
      final track = tracks.first;
      track.enabled = !track.enabled;
    }
  }

  /// 创建数据通道（可选，用于文字直连）
  Future<void> createDataChannel() async {
    if (_pc == null) return;
    _dataChannel = await _pc!.createDataChannel(
      'voice',
      RTCDataChannelInit(),
    );
    _bindDataChannel(_dataChannel!);
  }

  void _setupPcListeners() {
    _pc!.onIceCandidate = (candidate) {
      final line = candidate.candidate;
      if (line == null || line.isEmpty) {
        return;
      }
      final info = iceStrategy.classifyCandidate(line);
      onRemoteCandidate(line, candidate.sdpMid, candidate.sdpMLineIndex);
      _updatePath(info);
    };

    _pc!.onIceConnectionState = (state) {
      _state = _mapIceState(state);
      onStateChanged(_state);
    };

    _pc!.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _state = CallState.connected;
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _state = CallState.disconnected;
          break;
        default:
          break;
      }
      onStateChanged(_state);
    };

    _pc!.onTrack = (event) {
      if (event.track.kind == 'audio') {
        _remoteStream = event.streams.isNotEmpty ? event.streams.first : null;
        event.track.enabled = true;
      }
    };

    _pc!.onDataChannel = (channel) {
      _dataChannel = channel;
      _bindDataChannel(channel);
    };
  }

  void _bindDataChannel(RTCDataChannel channel) {
    channel.onDataChannelState = (_) {};
    channel.onMessage = (message) {};
  }

  Future<void> _addLocalAudioTrack() async {
    if (_localStream == null) return;
    for (final track in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }
  }

  CallState _mapIceState(RTCIceConnectionState state) {
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
        return CallState.calling;
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        return CallState.connected;
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        return CallState.failed;
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        return CallState.disconnected;
      default:
        return _state;
    }
  }

  void _updatePath(IceCandidateInfo info) {
    _currentPath = info.label;
    onPathChanged(info);
  }

  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  void dispose() {
    hangup();
  }
}
