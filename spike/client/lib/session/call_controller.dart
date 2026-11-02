import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../ice/candidate.dart';
import '../ice/nic.dart';
import '../ice/nic_probe.dart';
import '../ice/path_stats.dart';
import '../ice/scheduler.dart';
import '../signaling/address.dart';
import '../signaling/events.dart';
import '../transfer/bytes.dart';
import '../transfer/chunk_pump.dart';
import '../transfer/messages.dart';
import 'rtc_config.dart';

const maxSpikeFileBytes = 256 * 1024 * 1024;

class CallController extends ChangeNotifier {
  String signalingUrl = 'ws://127.0.0.1:8787';
  String roomCode = '';
  Duration fallback = const Duration(seconds: 5);
  int chunkSize = 16 * 1024;

  String signalingState = '未连接';
  String role = '—';
  int peerCount = 0;
  String iceState = '—';
  String pcState = '—';
  String dcState = '—';
  String pathLabel = PathSnapshot.waiting.label;
  String pathDetail = PathSnapshot.waiting.detail;
  String schedulerText = '还没有开始收集候选';
  String? dtlsState;
  String? dtlsCipher;
  String? srtpCipher;
  bool dtlsActive = false;
  String? localFingerprint;
  String? remoteFingerprint;
  String? localCandidateType;
  String? localCandidateAddress;
  String? remoteCandidateType;
  String? remoteCandidateAddress;
  bool micAvailable = false;
  String? micError;
  bool remoteAudio = false;
  bool remoteAudioSeen = false;
  bool muted = false;
  int? lastSubmitMillis;
  int? lastReceiveMillis;
  double? lastMibps;
  bool? lastHashOk;
  int? lastBytes;
  String? receivePath;

  final List<NicInfo> nics = [];
  String? probeError;
  final List<String> logs = [];
  final List<String> chat = [];

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _ping;
  Timer? _tick;
  Timer? _stats;
  Timer? _autorunTimer;
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _localStream;
  CandidateScheduler? _scheduler;
  Future<void> _tail = Future<void>.value();
  final List<RTCIceCandidate> _pendingRemote = [];
  bool _remoteSet = false;
  bool _disposed = false;
  bool _autorun = false;
  bool _autorunSent = false;
  bool _autorunFinished = false;
  int _autorunBytes = 8 * 1024 * 1024;
  String? _autorunResult;
  bool textAckSeen = false;
  Completer<void>? _drainWaiter;
  _IncomingFile? _incoming;
  final List<Uint8List> _earlyBinary = [];
  Timer? _lateChunkTimer;
  String? _rejectId;

  Future<void> refreshNics() async {
    try {
      final found = await probeLocalNics();
      nics
        ..clear()
        ..addAll(found);
      probeError = found.isEmpty ? '没有枚举到网卡' : null;
      log(found.isEmpty ? '网卡枚举为空' : '网卡 ${found.length} 块');
    } catch (error) {
      probeError = '$error';
      log('网卡枚举失败：$error');
    }
  }

  Future<void> maybeAutorun() async {
    if (Platform.environment['SPIKE_AUTORUN'] != '1') return;
    _autorun = true;
    signalingUrl = Platform.environment['SPIKE_URL'] ?? signalingUrl;
    roomCode = Platform.environment['SPIKE_ROOM'] ?? 'autorun1';
    _autorunBytes = int.tryParse(Platform.environment['SPIKE_BYTES'] ?? '') ?? _autorunBytes;
    _autorunResult = Platform.environment['SPIKE_RESULT'];
    final chunk = int.tryParse(Platform.environment['SPIKE_CHUNK'] ?? '');
    if (chunk != null && chunk >= 1024) chunkSize = chunk;
    final seconds = int.tryParse(Platform.environment['SPIKE_FALLBACK_SECONDS'] ?? '');
    if (seconds != null && seconds >= 0) fallback = Duration(seconds: seconds);
    _autorunTimer = Timer(const Duration(seconds: 120), () {
      unawaited(_finishAutorun(2, {'error': 'timeout'}));
    });
    try {
      await connect();
    } catch (error) {
      await _finishAutorun(2, {'error': '$error'});
    }
  }

  Future<void> connect() async {
    if (signalingState == '已连接' || signalingState == '连接中') return;
    final url = buildSignalingUrl(signalingUrl, roomCode);
    signalingState = '连接中';
    log('连接 $url');
    _notify();
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 8));
      signalingState = '已连接';
      _sub = channel.stream.listen(_onSocketData, onError: (Object error) {
        log('信令错误：$error');
      }, onDone: () {
        signalingState = '已断开';
        log('信令连接已关闭');
        _notify();
      });
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 20), (_) => _sendRaw({'type': 'ping'}));
      _notify();
    } catch (error) {
      signalingState = '失败';
      log('信令连接失败：$error');
      _notify();
      rethrow;
    }
  }

  Future<void> checkHealth() async {
    final url = healthUrlFor(signalingUrl);
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 4));
      final response = await request.close().timeout(const Duration(seconds: 4));
      final body = await response.transform(utf8.decoder).join();
      log('健康检查 ${response.statusCode} $body');
    } catch (error) {
      log('健康检查失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> disconnect() async {
    _ping?.cancel();
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    signalingState = '已断开';
    await hangup(tellPeer: false);
  }

  Future<void> hangup({bool tellPeer = true}) async {
    if (tellPeer) _sendRaw({'type': 'signal', 'kind': 'bye'});
    await _closePeer();
    log(tellPeer ? '已挂断' : '已清理通话');
  }

  Future<void> recall() async {
    if (role != 'offerer') {
      log('只有先进入房间的一方可以重新呼叫');
      return;
    }
    await _closePeer();
    _enqueue(_startOffer);
  }

  void toggleMute() {
    muted = !muted;
    final tracks = _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[];
    for (final track in tracks) {
      track.enabled = !muted;
    }
    log(muted ? '已静音' : '已取消静音');
  }

  Future<bool> sendText(String body) async {
    final text = body.trim();
    if (text.isEmpty) return false;
    try {
      await _sendDcText(encodeText(text));
      chat.insert(0, '我：$text');
      if (chat.length > 100) chat.removeLast();
      _notify();
      return true;
    } catch (error) {
      log('发送文字失败：$error');
      return false;
    }
  }

  Future<void> sendTestPayload(int bytes) {
    return sendFileStream(name: 'spike-$bytes.bin', size: bytes, chunks: xorshiftBytes(bytes));
  }

  Future<void> sendFileStream({
    required String name,
    required int size,
    required Stream<List<int>> chunks,
  }) async {
    if (size > maxSpikeFileBytes) {
      log('spike 拒绝超过 ${maxSpikeFileBytes ~/ (1024 * 1024)} MiB 的文件');
      return;
    }
    final channel = _dc;
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      log('数据通道还没打开');
      return;
    }
    final id = _newId();
    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);
    final clock = Stopwatch()..start();
    try {
      await _sendDcText(encodeFileStart(id: id, name: name, size: size));
      final pump = ChunkPump(
        chunkSize: chunkSize,
        sendBinary: (bytes) => channel.send(RTCDataChannelMessage.fromBinary(bytes)),
        bufferedAmount: channel.getBufferedAmount,
        waitForDrain: _waitForDrain,
      );
      await pump.send(chunks, onChunk: input.add);
      input.close();
      output.close();
      final digest = output.events.single.toString();
      clock.stop();
      lastSubmitMillis = clock.elapsedMilliseconds;
      await _sendDcText(encodeFileEnd(id: id, sha256: digest, submitMillis: lastSubmitMillis!));
      log('文件已提交 $name，$size 字节，提交耗时 $lastSubmitMillis ms（含背压，不含对端确认）');
    } catch (error) {
      input.close();
      log('发送文件失败：$error');
      if (_autorun) await _finishAutorun(2, {'error': '$error'});
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ping?.cancel();
    _tick?.cancel();
    _stats?.cancel();
    _autorunTimer?.cancel();
    _lateChunkTimer?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_channel?.sink.close());
    unawaited(_closePeer());
    super.dispose();
  }

  void _onSocketData(dynamic data) {
    final text = data is String ? data : utf8.decode(data as List<int>);
    final event = parseServerEvent(text);
    switch (event) {
      case WelcomeEvent(:final role, :final peerCount):
        this.role = role;
        this.peerCount = peerCount;
        log('进入房间，角色 $role，人数 $peerCount');
        if (role == 'offerer' && peerCount >= 2) _enqueue(_startOffer);
      case PeerJoinedEvent(:final peerCount):
        this.peerCount = peerCount;
        log('对端已进入');
        if (role == 'offerer') _enqueue(_startOffer);
      case PeerLeftEvent():
        peerCount = 1;
        log('对端已离开');
        unawaited(_closePeer());
      case PongEvent():
        break;
      case ErrorEvent(:final error):
        log('信令错误：$error');
      case SignalOfferEvent(:final sdp):
        _enqueue(() => _onOffer(sdp));
      case SignalAnswerEvent(:final sdp):
        _enqueue(() => _onAnswer(sdp));
      case SignalCandidateEvent(:final candidate, :final sdpMid, :final sdpMLineIndex):
        _enqueue(() => _onRemoteCandidate(candidate, sdpMid, sdpMLineIndex));
      case SignalByeEvent():
        log('对端挂断');
        unawaited(_closePeer());
      case IgnoredEvent(:final reason):
        log('忽略信令消息：$reason');
    }
    _notify();
  }

  Future<void> _startOffer() async {
    if (_pc != null) return;
    await _startPeer();
    final pc = _pc;
    if (pc == null) return;
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _rememberFingerprint(local: true, sdp: offer.sdp);
    _sendRaw({'type': 'signal', 'kind': 'offer', 'sdp': offer.sdp});
    log('已发送 offer（${offer.sdp?.length ?? 0} 字节）');
    _flushCandidates();
  }

  Future<void> _onOffer(String sdp) async {
    if (_pc == null) await _startPeer();
    final pc = _pc;
    if (pc == null) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _remoteSet = true;
    _rememberFingerprint(local: false, sdp: sdp);
    await _flushRemoteCandidates();
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _rememberFingerprint(local: true, sdp: answer.sdp);
    _sendRaw({'type': 'signal', 'kind': 'answer', 'sdp': answer.sdp});
    log('已发送 answer（${answer.sdp?.length ?? 0} 字节）');
    _flushCandidates();
  }

  Future<void> _onAnswer(String sdp) async {
    final pc = _pc;
    if (pc == null) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _remoteSet = true;
    _rememberFingerprint(local: false, sdp: sdp);
    await _flushRemoteCandidates();
    log('已设置 answer');
  }

  Future<void> _onRemoteCandidate(String line, String? sdpMid, int? sdpMLineIndex) async {
    final ice = RTCIceCandidate(line, sdpMid, sdpMLineIndex);
    if (!_remoteSet || _pc == null) {
      _pendingRemote.add(ice);
      return;
    }
    await _pc!.addCandidate(ice);
  }

  Future<void> _flushRemoteCandidates() async {
    final pc = _pc;
    if (pc == null) return;
    final pending = List<RTCIceCandidate>.of(_pendingRemote);
    _pendingRemote.clear();
    for (final candidate in pending) {
      await pc.addCandidate(candidate);
    }
  }

  Future<void> _startPeer() async {
    await _closePeer();
    final pc = await createPeerConnection(buildPeerConnectionConfig());
    _pc = pc;
    _scheduler = CandidateScheduler(nics: nics, fallback: fallback);
    schedulerText = _scheduler!.describe();
    _remoteSet = false;
    _pendingRemote.clear();
    await _attachAudio(pc);
    pc.onIceCandidate = (candidate) {
      final line = candidate.candidate;
      if (line == null || line.isEmpty) {
        _scheduler?.markGatheringComplete();
        _flushCandidates();
        return;
      }
      final parsed = parseCandidateLine(line, nics);
      if (parsed == null || _scheduler == null) {
        _sendRaw({
          'type': 'signal',
          'kind': 'candidate',
          'candidate': line,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
        return;
      }
      _scheduler!.add(
        parsed,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
        now: DateTime.now(),
      );
      _flushCandidates();
    };
    pc.onIceConnectionState = (state) {
      iceState = _short(state);
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _scheduler?.seal();
        schedulerText = _scheduler?.describe() ?? schedulerText;
        unawaited(_refreshStats());
      }
      log('ICE $iceState');
    };
    pc.onConnectionState = (state) {
      pcState = _short(state);
      _notify();
    };
    pc.onTrack = (event) {
      if (event.track.kind == 'audio') {
        event.track.enabled = true;
        remoteAudio = true;
        remoteAudioSeen = true;
        log('收到远端音频轨道');
      }
    };
    pc.onDataChannel = _bindChannel;
    if (role == 'offerer') {
      _bindChannel(await pc.createDataChannel('spike', RTCDataChannelInit()..ordered = true));
    }
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) => _flushCandidates());
    _stats?.cancel();
    _stats = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_refreshStats()));
    log('PeerConnection 已创建。DTLS-SRTP 保持 libwebrtc 默认开启，没有应用层 E2EE。');
  }

  Future<void> _attachAudio(RTCPeerConnection pc) async {
    micError = null;
    micAvailable = false;
    try {
      final stream = await navigator.mediaDevices
          .getUserMedia({
            'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
            'video': false,
          })
          .timeout(const Duration(seconds: 8));
      _localStream = stream;
      for (final track in stream.getAudioTracks()) {
        await pc.addTrack(track, stream);
      }
      micAvailable = stream.getAudioTracks().isNotEmpty;
      log(micAvailable ? '已打开麦克风' : '没有拿到音频轨道');
    } catch (error) {
      micError = '$error';
      log('麦克风不可用，改为只协商音频收发：$error');
      try {
        await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
        );
      } catch (transceiverError) {
        log('添加音频 transceiver 失败：$transceiverError');
      }
    }
  }

  void _bindChannel(RTCDataChannel channel) {
    _dc = channel;
    channel.bufferedAmountLowThreshold = 256 * 1024;
    channel.onBufferedAmountLow = (amount) {
      final waiter = _drainWaiter;
      if (waiter != null && !waiter.isCompleted && amount <= 256 * 1024) {
        waiter.complete();
      }
    };
    channel.onDataChannelState = (state) {
      dcState = _short(state);
      if (state == RTCDataChannelState.RTCDataChannelOpen) unawaited(_onChannelOpen());
      _notify();
    };
    channel.onMessage = (message) {
      if (message.isBinary) {
        _onBinary(message.binary);
      } else {
        unawaited(_onTextMessage(message.text));
      }
    };
    final state = channel.state;
    dcState = state == null ? '—' : _short(state);
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      unawaited(_onChannelOpen());
    }
    log('数据通道 ${channel.label}');
  }

  Future<void> _onChannelOpen() async {
    log('数据通道已打开');
    if (_autorun && role == 'offerer' && !_autorunSent) {
      _autorunSent = true;
      final sent = await sendText('spike-hello');
      if (!sent) {
        await _finishAutorun(2, {'error': 'text send failed'});
        return;
      }
      await sendTestPayload(_autorunBytes);
    }
  }

  Future<void> _onTextMessage(String raw) async {
    final message = parseSpikeMessage(raw);
    switch (message) {
      case TextSpike(:final body):
        chat.insert(0, '对方：$body');
        if (chat.length > 100) chat.removeLast();
        log('收到文字');
        if (body == 'ack:spike-hello') textAckSeen = true;
        if (_autorun && role == 'answerer' && body == 'spike-hello') {
          await sendText('ack:spike-hello');
        }
      case FileStartSpike(:final id, :final name, :final size):
        await _incoming?.abandon();
        if (size > maxSpikeFileBytes) {
          _rejectId = id;
          _incoming = null;
          log('拒收 $name：超过 spike 上限');
          break;
        }
        _rejectId = null;
        final incoming = await _IncomingFile.begin(id: id, name: name, size: size);
        _incoming = incoming;
        for (final chunk in _earlyBinary) {
          incoming.add(chunk);
        }
        if (_earlyBinary.isNotEmpty) {
          log('补上 file-start 之前到达的 ${_earlyBinary.length} 个数据块');
        }
        _earlyBinary.clear();
        log('开始接收 $name（$size 字节）');
        _scheduleReceiveComplete();
      case FileEndSpike(:final id, :final sha256, :final submitMillis):
        if (_rejectId == id) {
          await _sendDcText(
            encodeFileResult(id: id, ok: false, bytes: 0, millis: 0, sha256: ''),
          );
          _rejectId = null;
          break;
        }
        final incoming = _incoming;
        if (incoming == null || incoming.id != id || incoming.completing) {
          log('收到无法匹配的 file-end');
          break;
        }
        incoming.endSha256 = sha256;
        incoming.endSubmitMillis = submitMillis;
        _scheduleReceiveComplete();
      case FileResultSpike(:final ok, :final bytes, :final millis, :final sha256):
        lastHashOk = ok;
        lastBytes = bytes;
        lastReceiveMillis = millis;
        lastMibps = millis == 0 ? null : bytes / 1024 / 1024 / (millis / 1000);
        log('对端确认 ${ok ? '通过' : '失败'}，$bytes 字节，$millis ms，${lastMibps?.toStringAsFixed(2) ?? '—'} MiB/s');
        if (_autorun && role == 'offerer') {
          await _finishAutorun(ok ? 0 : 2, {
            'bytes': bytes,
            'receiverMillis': millis,
            'mibPerSec': lastMibps,
            'sha256Ok': ok,
            'sha256': sha256,
            'submitMillis': lastSubmitMillis,
          });
        }
      case UnknownSpike():
        log('无法识别的数据通道文本');
    }
    _notify();
  }

  void _onBinary(Uint8List bytes) {
    if (_rejectId != null) return;
    final incoming = _incoming;
    if (incoming == null || incoming.completing) {
      _earlyBinary.add(Uint8List.fromList(bytes));
      return;
    }
    incoming.add(bytes);
    _scheduleReceiveComplete();
  }

  void _scheduleReceiveComplete() {
    final incoming = _incoming;
    if (incoming == null || incoming.endSha256 == null || incoming.completing) return;
    _lateChunkTimer?.cancel();
    if (incoming.bytes < incoming.size) {
      // file-end can arrive before the last binary chunks. Each new chunk
      // resets this, so a slow transfer is not cut off.
      _lateChunkTimer = Timer(const Duration(seconds: 2), () {
        unawaited(_completeIncoming(force: true));
      });
      return;
    }
    _lateChunkTimer = null;
    unawaited(_completeIncoming(force: false));
  }

  Future<void> _completeIncoming({required bool force}) async {
    final incoming = _incoming;
    if (incoming == null || incoming.completing || incoming.endSha256 == null) return;
    if (!force && incoming.bytes < incoming.size) return;
    incoming.completing = true;
    _lateChunkTimer?.cancel();
    _lateChunkTimer = null;
    _incoming = null;
    final submitMillis = incoming.endSubmitMillis ?? 0;
    final result = await incoming.finish(expectedSha256: incoming.endSha256!);
    lastReceiveMillis = result.millis;
    lastBytes = result.bytes;
    lastHashOk = result.ok;
    lastMibps = result.millis == 0 ? null : result.bytes / 1024 / 1024 / (result.millis / 1000);
    receivePath = result.path;
    log(
      '接收完成 ${result.ok ? '校验通过' : '校验失败'}，${result.bytes} 字节，'
      '${result.millis} ms，${lastMibps?.toStringAsFixed(2) ?? '—'} MiB/s，对端提交 $submitMillis ms',
    );
    await _sendDcText(
      encodeFileResult(
        id: incoming.id,
        ok: result.ok,
        bytes: result.bytes,
        millis: result.millis,
        sha256: result.sha256,
      ),
    );
    if (_autorun && role == 'answerer') {
      await Future<void>.delayed(const Duration(seconds: 1));
      await _finishAutorun(result.ok ? 0 : 2, {
        'bytes': result.bytes,
        'receiverMillis': result.millis,
        'mibPerSec': lastMibps,
        'sha256Ok': result.ok,
      });
    }
    _notify();
  }

  Future<void> _waitForDrain() {
    final waiter = Completer<void>();
    _drainWaiter = waiter;
    return Future.any([waiter.future, Future<void>.delayed(const Duration(milliseconds: 5))]);
  }

  Future<void> _sendDcText(String text) async {
    final channel = _dc;
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('数据通道还没打开');
    }
    await channel.send(RTCDataChannelMessage(text));
  }

  void _flushCandidates() {
    final scheduler = _scheduler;
    if (scheduler == null) return;
    final ready = scheduler.drain(DateTime.now());
    schedulerText = scheduler.describe();
    for (final item in ready) {
      _sendRaw({
        'type': 'signal',
        'kind': 'candidate',
        'candidate': item.parsed.signaledLine,
        'sdpMid': item.sdpMid,
        'sdpMLineIndex': item.sdpMLineIndex,
      });
      log('发布候选 ${item.parsed.tier.name} ${item.parsed.address}');
    }
    if (ready.isNotEmpty) _notify();
  }

  Future<void> _refreshStats() async {
    final pc = _pc;
    if (pc == null) return;
    try {
      final reports = await pc.getStats();
      final flat = <Map<String, dynamic>>[];
      for (final report in reports) {
        final map = <String, dynamic>{'id': report.id, 'type': report.type};
        report.values.forEach((key, value) => map['$key'] = value);
        flat.add(map);
      }
      final snapshot = interpretPath(flat, nics);
      pathLabel = snapshot.label;
      pathDetail = snapshot.detail;
      dtlsState = snapshot.dtlsState;
      dtlsCipher = snapshot.dtlsCipher;
      srtpCipher = snapshot.srtpCipher;
      dtlsActive = snapshot.dtlsActive;
      localCandidateType = snapshot.localType;
      localCandidateAddress = snapshot.localAddress;
      remoteCandidateType = snapshot.remoteType;
      remoteCandidateAddress = snapshot.remoteAddress;
      _notify();
    } catch (error) {
      log('getStats 失败：$error');
    }
  }

  void _rememberFingerprint({required bool local, required String? sdp}) {
    final fingerprint = parseFingerprint(sdp);
    if (fingerprint == null) return;
    if (local) {
      localFingerprint = fingerprint.toString();
    } else {
      remoteFingerprint = fingerprint.toString();
    }
    _notify();
  }

  void _sendRaw(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode(message));
  }

  void _enqueue(Future<void> Function() action) {
    _tail = _tail.then((_) async {
      try {
        await action();
      } catch (error) {
        log('通话错误：$error');
      }
    });
  }

  Future<void> _closePeer() async {
    _tick?.cancel();
    _stats?.cancel();
    _lateChunkTimer?.cancel();
    _lateChunkTimer = null;
    _earlyBinary.clear();
    _scheduler = null;
    _remoteSet = false;
    _pendingRemote.clear();
    await _incoming?.abandon();
    _incoming = null;
    final dc = _dc;
    _dc = null;
    final pc = _pc;
    _pc = null;
    final stream = _localStream;
    _localStream = null;
    try {
      await dc?.close();
    } catch (_) {}
    try {
      await pc?.close();
    } catch (_) {}
    try {
      await stream?.dispose();
    } catch (_) {}
    dcState = '—';
    iceState = '—';
    pcState = '—';
    remoteAudio = false;
    _notify();
  }

  Future<void> _finishAutorun(int code, Map<String, Object?> extra) async {
    if (!_autorun || _autorunFinished) return;
    _autorunFinished = true;
    _autorunTimer?.cancel();
    await _refreshStats();
    final payload = {
      'role': role,
      'path': pathLabel,
      'pathDetail': pathDetail,
      'scheduler': schedulerText,
      'dtlsState': dtlsState,
      'dtlsCipher': dtlsCipher,
      'srtpCipher': srtpCipher,
      'dtlsActive': dtlsActive,
      'localType': localCandidateType,
      'localAddress': localCandidateAddress,
      'remoteType': remoteCandidateType,
      'remoteAddress': remoteCandidateAddress,
      'micAvailable': micAvailable,
      'remoteAudio': remoteAudioSeen,
      'textAck': textAckSeen,
      'probeError': probeError,
      'nics': [for (final nic in nics) nic.label],
      ...extra,
    };
    final path = _autorunResult;
    if (path != null && path.isNotEmpty) {
      await File(path).writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    }
    exit(code);
  }

  void log(String message) {
    final now = DateTime.now().toIso8601String();
    final stamp = now.length >= 19 ? now.substring(11, 19) : now;
    logs.insert(0, '$stamp $message');
    if (logs.length > 300) logs.removeLast();
    if (_autorun) stdout.writeln(message);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _short(Object value) {
    final text = value.toString();
    final dot = text.lastIndexOf('.');
    return dot >= 0 ? text.substring(dot + 1) : text;
  }

  String _newId() {
    final random = Random.secure();
    return List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

class _IncomingFile {
  _IncomingFile({
    required this.id,
    required this.size,
    required this.path,
    required this._sink,
    required this._hash,
    required this._output,
  }) : _clock = Stopwatch()..start();

  final String id;
  final int size;
  final String path;
  final IOSink _sink;
  final ByteConversionSink _hash;
  final AccumulatorSink<Digest> _output;
  final Stopwatch _clock;
  int bytes = 0;
  String? endSha256;
  int? endSubmitMillis;
  bool completing = false;

  static Future<_IncomingFile> begin({required String id, required String name, required int size}) async {
    final dir = await Directory.systemTemp.createTemp('whisper-spike-');
    final path = '${dir.path}/${safeFileName(name)}';
    final sink = File(path).openWrite();
    final output = AccumulatorSink<Digest>();
    final hash = sha256.startChunkedConversion(output);
    return _IncomingFile(id: id, size: size, path: path, sink: sink, hash: hash, output: output);
  }

  void add(Uint8List chunk) {
    bytes += chunk.length;
    _hash.add(chunk);
    _sink.add(chunk);
  }

  Future<({bool ok, int bytes, int millis, String sha256, String path})> finish({
    required String expectedSha256,
  }) async {
    _hash.close();
    _output.close();
    await _sink.flush();
    await _sink.close();
    _clock.stop();
    final digest = _output.events.single.toString();
    final ok = digest == expectedSha256 && bytes == size;
    return (ok: ok, bytes: bytes, millis: _clock.elapsedMilliseconds, sha256: digest, path: path);
  }

  Future<void> abandon() async {
    try {
      _hash.close();
      _output.close();
      await _sink.close();
    } catch (_) {}
  }
}
