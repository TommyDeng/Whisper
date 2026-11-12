import 'dart:async';
import 'dart:typed_data';

import 'package:whisper/call/call_signal.dart';
import 'package:whisper/files/file_direct_link.dart';
import 'package:whisper/voice/ice_strategy.dart';

/// 一对内存里的假数据通道，测试用，不碰 WebRTC。
class FakeLinkPair {
  FakeLinkPair({this.path = IcePathType.lan, this.autoConnect = true}) {
    alice = FakeFileLink(this);
    bob = FakeFileLink(this);
  }

  IcePathType path;
  bool autoConnect;
  late final FakeFileLink alice;
  late final FakeFileLink bob;

  bool aliceOffered = false;
  bool bobAccepted = false;
  bool aliceAnswered = false;

  int aliceCreateCount = 0;
  int bobCreateCount = 0;

  /// 发出的二进制消息数（双方合计），用来确认 relay 路径没有传文件。
  int binarySent = 0;

  FakeFileLink linkFor(String side) => side == 'alice' ? alice : bob;

  void _maybeConnect() {
    if (!autoConnect) return;
    if (aliceOffered && bobAccepted && aliceAnswered) {
      alice.markConnected();
      bob.markConnected();
    }
  }

  void disconnect() {
    alice.fail();
    bob.fail();
  }
}

class FakeFileLink implements FileDirectLink {
  FakeFileLink(this.pair);

  final FakeLinkPair pair;

  final _candidates = StreamController<CallCandidate>();
  final _states = StreamController<FileLinkState>();
  final _paths = StreamController<IcePathType>.broadcast();
  final _messages = StreamController<FileLinkMessage>();

  bool closed = false;
  bool _connected = false;
  Completer<void>? gate;
  bool corruptNext = false;
  final early = <CallCandidate>[];

  IcePathType get path => pair.path;

  FakeFileLink get _peer => identical(this, pair.alice) ? pair.bob : pair.alice;

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
    if (identical(this, pair.alice)) {
      pair.aliceCreateCount++;
      pair.aliceOffered = true;
    } else {
      pair.bobCreateCount++;
    }
    early.forEach(_candidates.add);
    await Future<void>.delayed(Duration.zero);
    pair._maybeConnect();
    return 'offer-sdp';
  }

  @override
  Future<String> acceptOffer(String sdp) async {
    if (identical(this, pair.bob)) {
      pair.bobCreateCount++;
      pair.bobAccepted = true;
    } else {
      pair.aliceCreateCount++;
    }
    early.forEach(_candidates.add);
    await Future<void>.delayed(Duration.zero);
    pair._maybeConnect();
    return 'answer-sdp';
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    if (identical(this, pair.alice)) pair.aliceAnswered = true;
    await Future<void>.delayed(Duration.zero);
    pair._maybeConnect();
  }

  @override
  Future<void> addCandidate(CallCandidate candidate) async {}

  @override
  Future<IcePathType?> currentPath() async => path;

  @override
  Future<void> sendText(String text) async {
    if (closed) throw StateError('已关闭');
    await _deliver(FileLinkMessage.text(text));
  }

  @override
  Future<void> sendBinary(Uint8List bytes) async {
    if (closed) throw StateError('已关闭');
    if (gate != null) await gate!.future;
    if (closed) throw StateError('已关闭');
    var payload = bytes;
    if (corruptNext && payload.isNotEmpty) {
      corruptNext = false;
      payload = Uint8List.fromList(payload);
      payload[payload.length - 1] ^= 0xff;
    }
    pair.binarySent++;
    await _deliver(FileLinkMessage.binary(payload));
  }

  Future<void> _deliver(FileLinkMessage message) async {
    if (_peer.closed) return;
    _peer._messages.add(message);
  }

  @override
  Future<int> bufferedAmount() async => 0;

  @override
  Future<void> waitForDrain() async {}

  @override
  Future<void> close() async {
    closed = true;
  }

  void markConnected() {
    if (closed || _connected) return;
    _connected = true;
    _states.add(FileLinkState.connected);
    _paths.add(path);
  }

  void fail() {
    if (closed) return;
    _states.add(FileLinkState.failed);
  }

  void emitPath(IcePathType value) {
    pair.path = value;
    _paths.add(value);
  }
}
