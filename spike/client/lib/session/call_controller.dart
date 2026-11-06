import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
import '../transfer/direct_channel.dart';
import '../transfer/frames.dart';
import '../transfer/messages.dart';
import 'autorun_config.dart';
import 'progress_timeout.dart';
import 'rtc_config.dart';

const maxSpikeFileBytes = 256 * 1024 * 1024;

/// 等待对端 direct-listen 并建立 TCP 直连的最长时间。
/// 超过此时间仍未就绪，才回退到数据通道，避免 8 秒硬等导致过早放弃直连。
const directLinkWait = Duration(seconds: 15);

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
  bool _nicsReady = false;
  String? probeError;
  final List<String> logs = [];
  final List<String> chat = [];

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _ping;
  Timer? _tick;
  Timer? _stats;
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
  bool _spikeLog = false;
  int _autorunBytes = 8 * 1024 * 1024;
  String? _autorunResult;
  String? _preferredRole;
  PathTier? _onlyTier;
  int _holdSeconds = 0;
  int _waitSeconds = defaultWaitForPeer.inSeconds;
  String _fileTransport = 'datachannel';
  String _usedTransport = 'datachannel';
  int _bufferHigh = 1024 * 1024;
  int _bufferLow = 256 * 1024;
  Duration _pollInterval = const Duration(milliseconds: 5);
  int _directChunk = 256 * 1024;
  AutorunWatch? _watch;
  final DirectListener _directListener = DirectListener();
  DirectLink? _directLink;
  bool _directAnnouncing = false;
  bool _directAnnounced = false;
  bool _directConnecting = false;
  String? _directError;
  bool textAckSeen = false;
  bool textAckSent = false;
  bool _helloSeen = false;
  int _retransmittedFrames = 0;
  Completer<void>? _drainWaiter;
  _Receive? _receive;
  final Map<int, Uint8List> _earlyFrames = {};
  final Map<int, int> _resendCount = {};
  List<Uint8List>? _sentPayloads;
  String? _sendingId;
  Completer<void>? _startAck;
  Completer<void>? _textAck;
  Completer<FileResultSpike>? _fileResult;
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
    } finally {
      _nicsReady = true;
      _scheduler?.noteNicMapReady();
      _flushCandidates();
    }
  }

  Future<void> maybeAutorun() async {
    if (Platform.environment['SPIKE_AUTORUN'] != '1') return;
    _spikeLog = Platform.environment['SPIKE_LOG'] == '1';
    final delayJoin = int.tryParse(Platform.environment['SPIKE_DELAY_JOIN'] ?? '');
    if (delayJoin != null && delayJoin > 0) {
      log('SPIKE_DELAY_JOIN：延迟 $delayJoin 秒再连接');
      await Future<void>.delayed(Duration(seconds: delayJoin));
    }
    _autorun = true;
    signalingUrl = Platform.environment['SPIKE_URL'] ?? signalingUrl;
    roomCode = Platform.environment['SPIKE_ROOM'] ?? 'autorun1';
    final bytesEnv = Platform.environment['SPIKE_BYTES'];
    if (bytesEnv != null && bytesEnv.isNotEmpty) {
      _autorunBytes = int.tryParse(bytesEnv) ?? _autorunBytes;
    }
    _autorunResult = Platform.environment['SPIKE_RESULT'];
    _preferredRole = preferredAutorunRole(
      spikeRole: Platform.environment['SPIKE_ROLE'],
      hasSpikeBytes: bytesEnv != null && bytesEnv.isNotEmpty,
    );
    final chunk = int.tryParse(Platform.environment['SPIKE_CHUNK'] ?? '');
    if (chunk != null && chunk >= 1024) chunkSize = chunk;
    final seconds = int.tryParse(Platform.environment['SPIKE_FALLBACK_SECONDS'] ?? '');
    if (seconds != null && seconds >= 0) fallback = Duration(seconds: seconds);
    try {
      _onlyTier = parseOnlyTier(Platform.environment['SPIKE_ONLY_TIER']);
      _holdSeconds = parseHoldSeconds(Platform.environment['SPIKE_HOLD_SECONDS']);
      _waitSeconds = parseWaitSeconds(Platform.environment['SPIKE_WAIT_SECONDS']);
      _fileTransport = parseFileTransport(Platform.environment['SPIKE_FILE_TRANSPORT']);
      final high = int.tryParse(Platform.environment['SPIKE_BUFFER_HIGH_KB'] ?? '');
      final low = int.tryParse(Platform.environment['SPIKE_BUFFER_LOW_KB'] ?? '');
      final poll = int.tryParse(Platform.environment['SPIKE_POLL_MS'] ?? '');
      final directChunk = int.tryParse(Platform.environment['SPIKE_DIRECT_CHUNK_KB'] ?? '');
      if (high != null && high > 0) _bufferHigh = high * 1024;
      if (low != null && low >= 0) _bufferLow = low * 1024;
      if (poll != null && poll >= 0) _pollInterval = Duration(milliseconds: poll);
      if (directChunk != null && directChunk >= 16) _directChunk = directChunk * 1024;
    } catch (error) {
      await _finishAutorun(2, {'error': '$error'});
      return;
    }
    _watch = AutorunWatch(
      waitForPeer: Duration(seconds: _waitSeconds),
      onWaitTimeout: () {
        unawaited(_finishAutorun(2, {'error': 'wait-timeout'}));
      },
      onStall: _onAutorunStall,
    );
    _watch!.start();
    try {
      await connect();
    } catch (error) {
      await _finishAutorun(2, {'error': '$error'});
    }
  }

  Future<void> connect() async {
    if (signalingState == '已连接' || signalingState == '连接中') return;
    final url = buildSignalingUrl(signalingUrl, roomCode, role: _preferredRole);
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
      log('只有 offerer 可以重新呼叫');
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
    _watch?.beginTransfer();
    if (_fileTransport == 'direct' && _directLink == null) {
      _logDirect('直连尚未就绪，等待对端 direct-listen（最多 ${directLinkWait.inSeconds} 秒）...');
      final deadline = DateTime.now().add(directLinkWait);
      while (_directLink == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    final payloads = await _collectPayloads(chunks, size);
    final id = _newId();
    _sendingId = id;
    _sentPayloads = payloads;
    _resendCount.clear();
    _retransmittedFrames = 0;
    final startAck = Completer<void>();
    _startAck = startAck;
    final resultWait = Completer<FileResultSpike>();
    _fileResult = resultWait;
    try {
      final digest = ChunkAssembler.hashPayloads(payloads);
      if (_fileTransport == 'direct' && _directLink != null) {
        _usedTransport = 'direct';
        final clock = Stopwatch()..start();
        await _directLink!.sendFile(
          id: id,
          name: name,
          payloads: payloads,
          sha256Hex: digest,
          chunkSize: _directChunk,
          onProgress: _noteAutorunProgress,
        );
        clock.stop();
        lastSubmitMillis = clock.elapsedMilliseconds;
        log('直连已提交 $name，$size 字节，提交耗时 $lastSubmitMillis ms');
        final result = await resultWait.future.timeout(const Duration(minutes: 3));
        if (!result.ok) log('对端校验失败');
        return;
      }
      if (_fileTransport == 'direct') {
        _directError ??= '直连未就绪';
        log('直连未就绪，改走数据通道');
      }
      _usedTransport = 'datachannel';
      final start = encodeFileStart(
        id: id,
        name: name,
        size: size,
        chunkSize: chunkSize,
        chunks: payloads.length,
      );
      var acked = false;
      for (var attempt = 0; attempt < 5 && !acked; attempt++) {
        await _sendDcText(start);
        try {
          await startAck.future.timeout(const Duration(seconds: 2));
          acked = true;
        } on TimeoutException {
          log('还没收到 file-start-ack，重发文件头');
        }
      }
      if (!acked) throw StateError('对端没有确认文件头');
      final clock = Stopwatch()..start();
      await _sendFrames(payloads, List<int>.generate(payloads.length, (index) => index));
      clock.stop();
      lastSubmitMillis = clock.elapsedMilliseconds;
      await _sendDcText(encodeFileEnd(id: id, sha256: digest, submitMillis: lastSubmitMillis!));
      log('文件已提交 $name，$size 字节，${payloads.length} 块，提交耗时 $lastSubmitMillis ms');
      final result = await resultWait.future.timeout(const Duration(seconds: 60));
      if (!result.ok) {
        log('对端校验失败');
      }
    } catch (error) {
      log('发送文件失败：$error');
      if (_autorun) await _finishAutorun(2, {'error': '$error'});
    } finally {
      if (identical(_startAck, startAck)) _startAck = null;
      if (identical(_fileResult, resultWait) && !resultWait.isCompleted) {
        _fileResult = null;
      }
      _sendingId = null;
      _sentPayloads = null;
    }
  }

  Future<List<Uint8List>> _collectPayloads(Stream<List<int>> chunks, int size) async {
    final payloads = <Uint8List>[];
    final pending = BytesBuilder(copy: false);
    var total = 0;
    await for (final raw in chunks) {
      pending.add(raw);
      total += raw.length;
      if (total > maxSpikeFileBytes) {
        throw StateError('文件超过 spike 上限');
      }
      var buffered = pending.toBytes();
      var offset = 0;
      while (buffered.length - offset >= chunkSize) {
        payloads.add(Uint8List.fromList(buffered.sublist(offset, offset + chunkSize)));
        offset += chunkSize;
      }
      pending
        ..clear()
        ..add(buffered.sublist(offset));
    }
    final tail = pending.toBytes();
    if (tail.isNotEmpty) payloads.add(Uint8List.fromList(tail));
    final got = payloads.fold<int>(0, (sum, chunk) => sum + chunk.length);
    if (got != size) {
      throw StateError('读到 $got 字节，文件头声明 $size');
    }
    if (payloads.length != chunkCountFor(size, chunkSize)) {
      throw StateError('分块数量不一致');
    }
    return payloads;
  }

  Future<void> _sendFrames(List<Uint8List> payloads, List<int> sequences) async {
    final channel = _dc;
    if (channel == null) throw StateError('数据通道已关闭');
      var queued = 0;
    for (final sequence in sequences) {
      if (sequence < 0 || sequence >= payloads.length) continue;
      final frame = encodeChunkFrame(sequence, payloads[sequence]);
      await channel.send(RTCDataChannelMessage.fromBinary(frame));
      queued += frame.length;
      _watch?.onFrame();
      if (queued >= _bufferHigh) {
        await _waitUntilBuffered(channel, _bufferLow);
        queued = await channel.getBufferedAmount();
      }
    }
    await _waitUntilBuffered(channel, _bufferLow);
  }

  Future<void> _waitUntilBuffered(RTCDataChannel channel, int lowWater) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var amount = await channel.getBufferedAmount();
    while (amount > lowWater) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('数据通道发送缓冲在 30 秒内没有降下来');
      }
      await _waitForDrain();
      amount = await channel.getBufferedAmount();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ping?.cancel();
    _tick?.cancel();
    _stats?.cancel();
    _watch?.cancel();
    _receive?.nakTimer?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_channel?.sink.close());
    unawaited(_closePeer());
    super.dispose();
  }

  void _onSocketData(dynamic data) {
    if (_autorunFinished) return;
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
    _scheduler = CandidateScheduler(
      nics: nics,
      fallback: fallback,
      nicMapReady: _nicsReady,
      onlyTier: _onlyTier,
    );
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
        _scheduler?.refreshStatus();
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
    channel.bufferedAmountLowThreshold = _bufferLow;
    channel.onBufferedAmountLow = (amount) {
      final waiter = _drainWaiter;
      if (waiter != null && !waiter.isCompleted && amount <= _bufferLow) {
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
      final acked = await _helloAndWaitForAck();
      if (!acked) log('文字回执超时，仍继续传文件');
      if (_fileTransport == 'direct') {
        _logDirect('直连模式：不在通道打开时硬等，改在 sendFileStream 中等待对端 direct-listen');
      }
      await sendTestPayload(_autorunBytes);
    }
  }

  void _noteAutorunProgress() {
    _watch?.onFrame();
  }

  void _onAutorunStall() {
    final received = _receive?.assembler.receivedPayloadBytes;
    unawaited(_finishAutorun(2, {
      'error': 'stall',
      'bytes': received,
      'helloSeen': _helloSeen,
      'fileTransport': _usedTransport,
    }));
  }

  bool _pathAllowsDirect() {
    if (localCandidateType != 'host') return false;
    return pathLabel == '局域网' || pathLabel == 'ZeroTier';
  }

  Future<void> _maybeListenDirect() async {
    if (_fileTransport != 'direct' || role != 'answerer' || _directAnnounced || _directAnnouncing) return;
    if (localCandidateType == null || pathLabel == '等待') return;
    if (!_pathAllowsDirect()) {
      _directError = '选中的路径不是局域网或 ZeroTier host';
      return;
    }
    final local = localCandidateAddress;
    final localFp = localFingerprint;
    final remoteFp = remoteFingerprint;
    if (local == null || localFp == null || remoteFp == null) return;
    _directAnnouncing = true;
    try {
      final server = await _directListener.bindOnce(InternetAddress(local));
      final bound = '$local:${server.port}';
      final key = directFileKey(localFp, remoteFp);
      server.listen((socket) {
        unawaited(_acceptDirect(socket, key, bound));
      });
      _directAnnounced = true;
      await _sendDcText(encodeDirectListen(address: local, port: server.port));
      log('直连监听 $bound');
    } catch (error) {
      if (!_directAnnounced) _directAnnouncing = false;
      _directError = '$error';
      log('直连监听失败：$error');
    }
  }

  Future<void> _acceptDirect(Socket socket, Uint8List key, String bound) async {
    try {
      final link = await DirectLink.accept(socket: socket, key: key, boundAddress: bound);
      _directLink = link;
      _usedTransport = 'direct';
      _watch?.beginTransfer();
      final received = await link.receiveFile(onProgress: _noteAutorunProgress);
      _usedTransport = 'direct';
      lastBytes = received.bytes.length;
      lastHashOk = received.ok;
      lastReceiveMillis = received.millis;
      lastMibps = received.millis == 0 ? null : received.bytes.length / 1024 / 1024 / (received.millis / 1000);
      final dir = await Directory.systemTemp.createTemp('whisper-spike-');
      final path = '${dir.path}/${safeFileName(received.name)}';
      await File(path).writeAsBytes(received.bytes, flush: true);
      receivePath = path;
      log('直连接收完成 ${received.ok ? '校验通过' : '校验失败'}，${received.bytes.length} 字节，${received.millis} ms，${lastMibps?.toStringAsFixed(2) ?? '—'} MiB/s');
      await _sendDcText(
        encodeFileResult(
          id: received.id,
          ok: received.ok,
          bytes: received.bytes.length,
          millis: received.millis,
          sha256: received.sha256Hex,
        ),
      );
      if (_autorun && role == 'answerer') {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await _finishAutorun(received.ok ? 0 : 2, {
          'bytes': received.bytes.length,
          'receiverMillis': received.millis,
          'mibPerSec': lastMibps,
          'sha256Ok': received.ok,
          'sha256': received.sha256Hex,
          'helloSeen': _helloSeen,
          'fileTransport': 'direct',
        });
      }
    } catch (error) {
      _directError = '$error';
      log('直连接收失败：$error');
    }
  }

  Future<void> _connectDirect(String address, int port) async {
    if (_fileTransport != 'direct' || role != 'offerer' || _directLink != null || _directConnecting) return;
    final localFp = localFingerprint;
    final remoteFp = remoteFingerprint;
    if (localFp == null || remoteFp == null) return;
    _directConnecting = true;
    try {
      final link = await DirectLink.connect(
        host: address,
        port: port,
        key: directFileKey(localFp, remoteFp),
        sourceAddress: localCandidateAddress == null ? null : InternetAddress.tryParse(localCandidateAddress!),
      );
      _directLink = link;
      _usedTransport = 'direct';
      log('直连已接通 $address:$port');
    } catch (error) {
      _directError = '$error';
      log('直连连接失败：$error');
    }
  }

  Future<bool> _helloAndWaitForAck() async {
    final wait = Completer<void>();
    _textAck = wait;
    final sent = await sendText('spike-hello');
    if (!sent) {
      _textAck = null;
      await _finishAutorun(2, {'error': 'text send failed'});
      return false;
    }
    try {
      await wait.future.timeout(const Duration(seconds: 5));
      return true;
    } on TimeoutException {
      return textAckSeen;
    } finally {
      if (identical(_textAck, wait)) _textAck = null;
    }
  }

  Future<void> _onTextMessage(String raw) async {
    if (_autorunFinished) return;
    final message = parseSpikeMessage(raw);
    switch (message) {
      case TextSpike(:final body):
        chat.insert(0, '对方：$body');
        if (chat.length > 100) chat.removeLast();
        log('收到文字');
        if (body == 'ack:spike-hello') _noteTextAck();
        if (_autorun && role == 'answerer' && body == 'spike-hello') {
          _helloSeen = true;
          unawaited(_sendTextAck());
        }
      case TextAckSpike(:final body):
        log('收到文字回执');
        if (body == 'spike-hello') _noteTextAck();
      case FileStartSpike(:final id, :final name, :final size, :final chunkSize, :final chunks):
        await _beginReceive(id: id, name: name, size: size, chunkSize: chunkSize, chunks: chunks);
      case FileStartAckSpike(:final id):
        if (id == _sendingId && _startAck != null && !_startAck!.isCompleted) {
          _startAck!.complete();
        }
      case FileNakSpike(:final id, :final missing):
        if (id == _sendingId) unawaited(_retransmit(missing));
      case DirectListenSpike(:final address, :final port):
        unawaited(_connectDirect(address, port));
      case FileEndSpike(:final id, :final sha256, :final submitMillis):
        final receive = _receive;
        if (receive == null || receive.id != id) {
          log('收到无法匹配的 file-end');
          break;
        }
        receive.endSha256 = sha256;
        receive.endSubmitMillis = submitMillis;
        _considerReceive();
      case final FileResultSpike result:
        lastHashOk = result.ok;
        lastBytes = result.bytes;
        lastReceiveMillis = result.millis;
        lastMibps = result.millis == 0 ? null : result.bytes / 1024 / 1024 / (result.millis / 1000);
        log('对端确认 ${result.ok ? '通过' : '失败'}，${result.bytes} 字节，${result.millis} ms，${lastMibps?.toStringAsFixed(2) ?? '—'} MiB/s');
        final waiting = _fileResult;
        if (waiting != null && !waiting.isCompleted) waiting.complete(result);
        if (_autorun && role == 'offerer') {
          await _finishAutorun(result.ok ? 0 : 2, {
            'bytes': result.bytes,
            'receiverMillis': result.millis,
            'mibPerSec': lastMibps,
            'sha256Ok': result.ok,
            'sha256': result.sha256,
            'submitMillis': lastSubmitMillis,
            'retransmittedFrames': _retransmittedFrames,
          });
        }
      case UnknownSpike():
        log('无法识别的数据通道文本');
    }
    _notify();
  }

  void _noteTextAck() {
    textAckSeen = true;
    final wait = _textAck;
    if (wait != null && !wait.isCompleted) wait.complete();
    _notify();
  }

  Future<void> _sendTextAck() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _sendDcText(encodeTextAck('spike-hello'));
        textAckSent = true;
      } catch (error) {
        log('文字回执发送失败，重试：$error');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    log('已发送文字回执');
  }

  Future<void> _beginReceive({
    required String id,
    required String name,
    required int size,
    required int chunkSize,
    required int chunks,
  }) async {
    _receive?.nakTimer?.cancel();
    if (size > maxSpikeFileBytes || chunks != chunkCountFor(size, chunkSize)) {
      _rejectId = id;
      _receive = null;
      log('拒收 $name：大小或分块数量不对');
      await _sendDcText(encodeFileResult(id: id, ok: false, bytes: 0, millis: 0, sha256: ''));
      return;
    }
    _rejectId = null;
    _watch?.beginTransfer();
    final receive = _Receive(
      id: id,
      name: name,
      assembler: ChunkAssembler(size: size, chunkSize: chunkSize),
    );
    _receive = receive;
    var applied = 0;
    for (final entry in _earlyFrames.entries) {
      final frame = decodeChunkFrame(entry.value);
      if (frame != null && receive.assembler.addFrame(frame)) applied++;
    }
    _earlyFrames.clear();
    if (applied > 0) log('按序号放入文件头之前到达的 $applied 块');
    log('开始接收 $name（$size 字节，$chunks 块）');
    await _sendDcText(encodeFileStartAck(id));
    _considerReceive();
  }

  void _onBinary(Uint8List bytes) {
    if (_rejectId != null) return;
    final copy = Uint8List.fromList(bytes);
    final frame = decodeChunkFrame(copy);
    if (frame == null) {
      log('忽略无法识别的二进制帧');
      return;
    }
    final receive = _receive;
    if (receive == null || receive.finishing) {
      _earlyFrames[frame.sequence] = copy;
      return;
    }
    receive.assembler.addFrame(frame);
    _noteAutorunProgress();
    _considerReceive();
  }

  void _considerReceive() {
    final receive = _receive;
    if (receive == null || receive.finishing || receive.endSha256 == null) return;
    if (receive.assembler.complete) {
      unawaited(_finishReceive(giveUp: false));
      return;
    }
    if (receive.nakTimer != null) return;
    unawaited(_nakReceive());
    receive.nakTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      unawaited(_nakReceive());
    });
  }

  Future<void> _nakReceive() async {
    final receive = _receive;
    if (receive == null || receive.finishing || receive.endSha256 == null) return;
    if (receive.assembler.complete) {
      await _finishReceive(giveUp: false);
      return;
    }
    receive.naks += 1;
    final missing = receive.assembler.missingSequences();
    log('缺少 ${missing.length} 块，请求重传');
    await _sendDcText(encodeFileNak(id: receive.id, missing: missing));
    if (receive.naks >= 8) {
      await _finishReceive(giveUp: true);
    }
  }

  Future<void> _retransmit(List<int> missing) async {
    final payloads = _sentPayloads;
    if (payloads == null || missing.isEmpty) return;
    final todo = <int>[];
    for (final sequence in missing) {
      final count = (_resendCount[sequence] ?? 0) + 1;
      if (count > 8) continue;
      _resendCount[sequence] = count;
      todo.add(sequence);
    }
    if (todo.isEmpty) return;
    _retransmittedFrames += todo.length;
    log('重传 ${todo.length} 块');
    await _sendFrames(payloads, todo);
  }

  Future<void> _finishReceive({required bool giveUp}) async {
    final receive = _receive;
    if (receive == null || receive.finishing) return;
    if (!giveUp && !receive.assembler.complete) return;
    receive.finishing = true;
    receive.nakTimer?.cancel();
    _receive = null;
    final submitMillis = receive.endSubmitMillis ?? 0;
    String digest = '';
    var ok = false;
    String? path;
    if (receive.assembler.complete) {
      final dir = await Directory.systemTemp.createTemp('whisper-spike-');
      path = '${dir.path}/${safeFileName(receive.name)}';
      final sink = File(path).openWrite();
      digest = receive.assembler.writeAndHash(sink);
      await sink.flush();
      await sink.close();
      ok = digest == receive.endSha256 && receive.assembler.receivedPayloadBytes == receive.assembler.size;
    }
    final millis = receive.clock.elapsedMilliseconds;
    lastReceiveMillis = millis;
    lastBytes = receive.assembler.receivedPayloadBytes;
    lastHashOk = ok;
    lastMibps = millis == 0 ? null : lastBytes! / 1024 / 1024 / (millis / 1000);
    receivePath = path;
    log(
      '接收完成 ${ok ? '校验通过' : '校验失败'}，$lastBytes 字节，'
      '$millis ms，${lastMibps?.toStringAsFixed(2) ?? '—'} MiB/s，对端提交 $submitMillis ms',
    );
    await _sendDcText(
      encodeFileResult(
        id: receive.id,
        ok: ok,
        bytes: receive.assembler.receivedPayloadBytes,
        millis: millis,
        sha256: digest,
      ),
    );
    if (_autorun && role == 'answerer') {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _finishAutorun(ok ? 0 : 2, {
        'bytes': lastBytes,
        'receiverMillis': millis,
        'mibPerSec': lastMibps,
        'sha256Ok': ok,
        'sha256': digest,
        'retransmittedFrames': _retransmittedFrames,
        'helloSeen': _helloSeen,
      });
    }
    _notify();
  }

  Future<void> _waitForDrain() {
    final waiter = Completer<void>();
    _drainWaiter = waiter;
    return Future.any([waiter.future, Future<void>.delayed(_pollInterval)]);
  }

  Future<void> _sendDcText(String text) async {
    for (var attempt = 0; attempt < 25; attempt++) {
      final channel = _dc;
      if (channel != null && channel.state == RTCDataChannelState.RTCDataChannelOpen) {
        await channel.send(RTCDataChannelMessage(text));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    throw StateError('数据通道还没打开');
  }

  void _flushCandidates() {
    final scheduler = _scheduler;
    if (scheduler == null) return;
    scheduler.refreshStatus();
    final ready = scheduler.drain(DateTime.now());
    schedulerText = scheduler.describe();
    for (final item in ready) {
      _sendRaw({
        'type': 'signal',
        'kind': 'candidate',
        'candidate': scheduler.lineToSignal(item),
        'sdpMid': item.sdpMid,
        'sdpMLineIndex': item.sdpMLineIndex,
      });
      log('发布候选 ${scheduler.tierOf(item).name} ${item.parsed.address}');
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
      if (_fileTransport == 'direct') unawaited(_maybeListenDirect());
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
    _receive?.nakTimer?.cancel();
    _receive = null;
    _earlyFrames.clear();
    _sentPayloads = null;
    _sendingId = null;
    _scheduler = null;
    _remoteSet = false;
    _pendingRemote.clear();
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
    _watch?.cancel();
    await _refreshStats();
    _scheduler?.refreshStatus();
    if (_scheduler != null) schedulerText = _scheduler!.describe();
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
    final path = autorunResultPath(spikeResult: _autorunResult, role: role);
    payload['resultPath'] = path;
    payload['preferredRole'] = _preferredRole;
    payload['textAck'] = textAckSeen;
    payload['textAckSent'] = textAckSent;
    payload['onlyTier'] = _onlyTier?.name;
    payload['fileTransport'] = _usedTransport;
    if (_directError != null) payload['directError'] = _directError;
    await File(path).writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    if (_holdSeconds > 0) {
      log('结果已写入，窗口再保持 $_holdSeconds 秒');
      await Future<void>.delayed(Duration(seconds: _holdSeconds));
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

  void _logDirect(String message) {
    if (!_spikeLog) return;
    log('[direct] $message');
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

class _Receive {
  _Receive({required this.id, required this.name, required this.assembler}) : clock = Stopwatch()..start();

  final String id;
  final String name;
  final ChunkAssembler assembler;
  final Stopwatch clock;
  String? endSha256;
  int? endSubmitMillis;
  int naks = 0;
  Timer? nakTimer;
  bool finishing = false;
}
