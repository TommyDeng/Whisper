/// 大文件直传用的数据通道：一个 WebRTC PeerConnection，没有音视频。
///
/// 文件内容另用 FileCipher 加密；这里只负责建立点对点通道。
/// 不加入 TURN，选中候选对如果是 relay，由上层拒绝。见 docs/file-direct.md。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../call/call_signal.dart';
import '../call/webrtc_call_media.dart';
import '../session/rtc_config.dart';
import '../voice/ice_strategy.dart';

/// 数据通道上的一条消息。
class FileLinkMessage {
  const FileLinkMessage.text(this.text) : bytes = null;
  const FileLinkMessage.binary(this.bytes) : text = null;

  final String? text;
  final Uint8List? bytes;

  bool get isBinary => bytes != null;
}

enum FileLinkState { connected, failed, closed }

/// 一次直传用的点对点连接。每次传输新建，用完 [close]。
abstract class FileDirectLink {
  /// 主叫：建好数据通道，生成 SDP offer。
  Future<String> createOffer();

  /// 被叫：应用对方的 offer，生成 SDP answer。
  Future<String> acceptOffer(String sdp);

  /// 主叫：应用对方的 answer。
  Future<void> acceptAnswer(String sdp);

  /// 加入对方的一个 ICE 候选。只能在 [acceptOffer] / [acceptAnswer] 完成之后调用。
  Future<void> addCandidate(CallCandidate candidate);

  /// 本端收集到的 ICE 候选。可能在 offer / answer 返回之前就开始发出。
  Stream<CallCandidate> get candidates;

  /// 连接状态变化。
  Stream<FileLinkState> get states;

  /// 当前选中的 ICE 路径；还没连上或拿不到统计时为 null。
  Future<IcePathType?> currentPath();

  /// 路径变化（广播流）。
  Stream<IcePathType> get paths;

  Future<void> sendText(String text);

  Future<void> sendBinary(Uint8List bytes);

  Stream<FileLinkMessage> get messages;

  Future<int> bufferedAmount();

  /// 等到发送缓冲降到低水位，或通道已关闭。
  Future<void> waitForDrain();

  /// 关闭连接。可以重复调用。
  Future<void> close();
}

/// 只含 STUN、不含 TURN 的 PeerConnection 配置。文件不得走 TURN。
Map<String, dynamic> buildFilePeerConnectionConfig() => {
  'iceServers': [
    {'urls': defaultStunUrl},
  ],
  'sdpSemantics': 'unified-plan',
  'bundlePolicy': 'max-bundle',
  'rtcpMuxPolicy': 'require',
  'iceCandidatePoolSize': 0,
};

class WebRtcFileLink implements FileDirectLink {
  WebRtcFileLink({Map<String, dynamic>? config})
    : _config = config ?? buildFilePeerConnectionConfig();

  final Map<String, dynamic> _config;

  final _candidates = StreamController<CallCandidate>();
  final _states = StreamController<FileLinkState>();
  final _paths = StreamController<IcePathType>.broadcast();
  final _messages = StreamController<FileLinkMessage>();
  final _drain = StreamController<void>.broadcast();

  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  bool _closed = false;
  bool _connected = false;
  IcePathType? _path;
  @override
  Stream<CallCandidate> get candidates => _candidates.stream;

  @override
  Stream<FileLinkState> get states => _states.stream;

  @override
  Stream<IcePathType> get paths => _paths.stream;

  @override
  Stream<FileLinkMessage> get messages => _messages.stream;

  @override
  Future<String> createOffer() async {
    final pc = await _open();
    final channel = await pc.createDataChannel(
      'whisper-file',
      RTCDataChannelInit(),
    );
    _attachChannel(channel);
    final offer = await pc.createOffer({
      'offerToReceiveAudio': false,
      'offerToReceiveVideo': false,
    });
    await pc.setLocalDescription(offer);
    return offer.sdp!;
  }

  @override
  Future<String> acceptOffer(String sdp) async {
    final pc = await _open();
    pc.onDataChannel = (channel) {
      if (_closed) return;
      _attachChannel(channel);
    };
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
  Future<IcePathType?> currentPath() async {
    await _refreshPath();
    return _path;
  }

  @override
  Future<void> sendText(String text) async {
    final channel = _channel;
    if (channel == null || _closed) throw StateError('数据通道不可用');
    await channel.send(RTCDataChannelMessage(text));
  }

  @override
  Future<void> sendBinary(Uint8List bytes) async {
    final channel = _channel;
    if (channel == null || _closed) throw StateError('数据通道不可用');
    await channel.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  @override
  Future<int> bufferedAmount() async {
    final channel = _channel;
    if (channel == null) return 0;
    try {
      return await channel.getBufferedAmount();
    } catch (_) {
      return channel.bufferedAmount ?? 0;
    }
  }

  @override
  Future<void> waitForDrain() async {
    if (_closed) return;
    final amount = await bufferedAmount();
    if (amount <= FileDirectProtocolLowWater.lowWater) return;
    try {
      await _drain.stream.first.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw StateError('数据通道发送缓冲没有降下来');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final channel = _channel;
    final pc = _pc;
    _channel = null;
    _pc = null;
    try {
      await channel?.close();
    } catch (_) {}
    try {
      await pc?.close();
    } catch (_) {}
    if (!_states.isClosed) _states.add(FileLinkState.closed);
    await _candidates.close();
    await _states.close();
    await _paths.close();
    await _messages.close();
    await _drain.close();
  }

  Future<RTCPeerConnection> _open() async {
    if (_closed) throw StateError('已关闭');
    final pc = await createPeerConnection(_config);
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
          unawaited(_refreshPath());
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _states.add(FileLinkState.failed);
        default:
          break;
      }
    };
    pc.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        unawaited(_refreshPath());
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        if (!_closed) _states.add(FileLinkState.failed);
      }
    };
    return pc;
  }

  void _attachChannel(RTCDataChannel channel) {
    _channel = channel;
    channel.bufferedAmountLowThreshold = FileDirectProtocolLowWater.lowWater;
    channel.onBufferedAmountLow = (_) {
      if (!_drain.isClosed) _drain.add(null);
    };
    channel.onMessage = (message) {
      if (_closed || _messages.isClosed) return;
      if (message.isBinary) {
        _messages.add(
          FileLinkMessage.binary(Uint8List.fromList(message.binary)),
        );
      } else {
        _messages.add(FileLinkMessage.text(message.text));
      }
    };
    void markOpen() {
      if (_closed || _connected) return;
      _connected = true;
      _states.add(FileLinkState.connected);
      unawaited(_refreshPath());
    }

    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      markOpen();
    }
    channel.onDataChannelState = (state) {
      if (_closed) return;
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        markOpen();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        if (_connected) _states.add(FileLinkState.failed);
      }
    };
  }

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
      // 拿不到统计信息不阻断直传，由上层在路径变成 relay 时再拒绝
    }
  }
}

/// 避免 file_direct_link 与 protocol 循环引用，把低水位常量单独放在这里。
class FileDirectProtocolLowWater {
  static const int lowWater = 256 * 1024;
}
