// 通话状态机。行为说明见 tasks/call-signaling/spec.md。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/call/call_service.dart';
import 'package:whisper/call/call_signal.dart';
import 'package:whisper/contact/contact.dart';

typedef SentSignal = ({Contact contact, CallSignal signal, String id});

class FakeTransport implements CallTransport {
  /// 发出的信令，按顺序。
  final List<SentSignal> sent = [];

  /// false 时 [send] 返回 null（没连上中继）。
  bool connected = true;

  final _incoming = StreamController<IncomingCallSignal>.broadcast();
  final _dropped = StreamController<({String sessionId, String id})>.broadcast();
  int _next = 0;

  @override
  Future<String?> send(Contact contact, String body) async {
    if (!connected) return null;
    final id = 'm${_next++}';
    sent.add((contact: contact, signal: CallSignal.decode(body)!, id: id));
    return id;
  }

  @override
  Stream<IncomingCallSignal> get incoming => _incoming.stream;

  @override
  Stream<({String sessionId, String id})> get dropped => _dropped.stream;

  void receive(Contact from, CallSignal signal) => _incoming.add(IncomingCallSignal(from, signal.encode()));

  void receiveRaw(Contact from, String body) => _incoming.add(IncomingCallSignal(from, body));

  void drop(String sessionId, String id) => _dropped.add((sessionId: sessionId, id: id));

  List<String> get kinds => [for (final item in sent) item.signal.kind];

  List<SentSignal> ofKind(String kind) => [for (final item in sent) if (item.signal.kind == kind) item];
}

class FakeMedia implements CallMedia {
  /// 被调用的方法，按顺序，例如 `acceptAnswer:sdp`。
  final List<String> log = [];

  final _candidates = StreamController<CallCandidate>();
  final _states = StreamController<CallMediaState>();

  Object? offerError;
  Object? acceptOfferError;

  /// createOffer / acceptOffer 返回之前先发出这些本端候选。
  List<CallCandidate> early = const [];

  /// 设置后 acceptAnswer / acceptOffer 要等它完成才返回。
  Completer<void>? gate;

  bool closed = false;
  bool muted = false;

  @override
  Future<String> createOffer() async {
    log.add('createOffer');
    if (offerError != null) throw offerError!;
    early.forEach(_candidates.add);
    await Future<void>.delayed(Duration.zero);
    return 'offer-sdp';
  }

  @override
  Future<String> acceptOffer(String sdp) async {
    log.add('acceptOffer:$sdp');
    if (acceptOfferError != null) throw acceptOfferError!;
    early.forEach(_candidates.add);
    await (gate?.future ?? Future<void>.delayed(Duration.zero));
    return 'answer-sdp';
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    log.add('acceptAnswer:$sdp');
    await (gate?.future ?? Future<void>.delayed(Duration.zero));
  }

  /// 第几次 ICE 重启。
  int restarts = 0;

  @override
  Future<String> restartOffer() async {
    restarts++;
    log.add('restartOffer');
    early.forEach(_candidates.add);
    await (gate?.future ?? Future<void>.delayed(Duration.zero));
    return 'restart-offer-$restarts';
  }

  @override
  Future<String> acceptRestartOffer(String sdp) async {
    log.add('acceptRestartOffer:$sdp');
    early.forEach(_candidates.add);
    await (gate?.future ?? Future<void>.delayed(Duration.zero));
    return 'restart-answer';
  }

  @override
  Future<void> addCandidate(CallCandidate candidate) async {
    log.add('addCandidate:${candidate.candidate}');
  }

  @override
  Stream<CallCandidate> get candidates => _candidates.stream;

  @override
  Stream<CallMediaState> get states => _states.stream;

  @override
  void setMuted(bool value) {
    muted = value;
    log.add('setMuted:$value');
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  void emitCandidate(String line) => _candidates.add(CallCandidate(line));

  void emitState(CallMediaState state) => _states.add(state);
}

Contact _contact(String deviceId, String sessionId) => Contact(
      deviceId: deviceId,
      name: deviceId,
      x25519PublicKeyBase64: '',
      ed25519PublicKeyBase64: '',
      safetyCode: '',
      isVerified: false,
      createdAt: 1,
      lastMessageTime: 0,
      sessionId: sessionId,
      peerRole: 'a',
    );

Future<void> _until(bool Function() condition, {String what = '条件'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$what');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  final bob = _contact('bob', 'session-bob');
  final carol = _contact('carol', 'session-carol');

  late FakeTransport transport;
  late List<FakeMedia> medias;
  late CallService service;

  /// 下一个被创建的 FakeMedia 的预设。
  void Function(FakeMedia media)? prepare;

  CallService newService({
    Duration ringTimeout = const Duration(seconds: 20),
    Duration connectTimeout = const Duration(seconds: 20),
    Duration reconnectTimeout = const Duration(seconds: 20),
    Duration reconnectGrace = const Duration(seconds: 20),
    Duration reconnectRetry = const Duration(seconds: 20),
  }) =>
      CallService(
        transport: transport,
        createMedia: (_) {
          final media = FakeMedia();
          prepare?.call(media);
          medias.add(media);
          return media;
        },
        ringTimeout: ringTimeout,
        connectTimeout: connectTimeout,
        reconnectTimeout: reconnectTimeout,
        reconnectGrace: reconnectGrace,
        reconnectRetry: reconnectRetry,
      );

  Future<void> phase(CallPhase expected) =>
      _until(() => service.snapshot.phase == expected, what: '进入 $expected（现在是 ${service.snapshot.phase}）');

  /// 呼叫 Bob，返回这通通话的 callId。
  Future<String> call() async {
    await service.start(bob);
    expect(service.snapshot.phase, CallPhase.outgoing);
    return service.snapshot.callId!;
  }

  /// Bob 打进来，等到响铃。
  Future<void> ring({String callId = 'in-1', Contact? from}) async {
    transport.receive(from ?? bob, CallSignal.offer(callId, 'remote-offer'));
    await phase(CallPhase.incoming);
  }

  setUp(() {
    transport = FakeTransport();
    medias = [];
    prepare = null;
    service = newService();
  });

  tearDown(() => service.dispose());

  test('初始状态是 idle', () {
    final snapshot = service.snapshot;
    expect(snapshot.phase, CallPhase.idle);
    expect(snapshot.contact, isNull);
    expect(snapshot.callId, isNull);
    expect(snapshot.endReason, isNull);
  });

  group('呼出', () {
    test('start 打开媒体并发出 offer', () async {
      await service.start(bob);

      final snapshot = service.snapshot;
      expect(snapshot.phase, CallPhase.outgoing);
      expect(snapshot.contact!.deviceId, 'bob');
      expect(snapshot.isOutgoing, isTrue);
      expect(snapshot.remoteRinging, isFalse);
      expect(snapshot.callId, isNotEmpty);

      expect(medias, hasLength(1));
      expect(medias.single.log, ['createOffer']);
      expect(transport.kinds, [CallSignal.kindOffer]);
      final offer = transport.sent.single;
      expect(offer.contact.sessionId, 'session-bob');
      expect(offer.signal.callId, snapshot.callId);
      expect(offer.signal.sdp, 'offer-sdp');
    });

    test('每通通话的 callId 都不同', () async {
      final first = await call();
      await service.hangup();
      final second = await call();
      expect(second, isNot(first));
    });

    test('没连上中继：直接以 offline 结束，媒体关闭', () async {
      transport.connected = false;
      await service.start(bob);

      expect(service.snapshot.phase, CallPhase.ended);
      expect(service.snapshot.endReason, CallEndReason.offline);
      expect(service.snapshot.contact!.deviceId, 'bob');
      expect(medias.single.closed, isTrue);
      expect(transport.sent, isEmpty);
    });

    test('中继丢弃了 offer（对方不在线）：以 offline 结束，不再发任何信令', () async {
      await call();
      transport.drop('session-bob', transport.sent.single.id);
      await phase(CallPhase.ended);

      expect(service.snapshot.endReason, CallEndReason.offline);
      expect(medias.single.closed, isTrue);
      expect(transport.kinds, [CallSignal.kindOffer]);
    });

    test('别的会话或别的消息被丢弃不影响通话', () async {
      await call();
      transport.drop('session-carol', transport.sent.single.id);
      transport.drop('session-bob', 'something-else');
      await _settle();
      expect(service.snapshot.phase, CallPhase.outgoing);
    });

    test('打不开麦克风：以 failed 结束，不发任何信令，start 不抛异常', () async {
      prepare = (media) => media.offerError = StateError('no mic');
      await service.start(bob);

      expect(service.snapshot.phase, CallPhase.ended);
      expect(service.snapshot.endReason, CallEndReason.failed);
      expect(medias.single.closed, isTrue);
      expect(transport.sent, isEmpty);
    });

    test('对方响铃', () async {
      final callId = await call();
      transport.receive(bob, CallSignal.ringing(callId));
      await _until(() => service.snapshot.remoteRinging, what: 'remoteRinging');
      expect(service.snapshot.phase, CallPhase.outgoing);
    });

    test('对方接听：应用 answer 进入 connecting，媒体连上后进入 active', () async {
      final callId = await call();
      transport.receive(bob, CallSignal.answer(callId, 'remote-answer'));
      await phase(CallPhase.connecting);
      expect(medias.single.log, ['createOffer', 'acceptAnswer:remote-answer']);
      expect(service.snapshot.connectedAt, isNull);

      medias.single.emitState(CallMediaState.connected);
      await phase(CallPhase.active);
      expect(service.snapshot.connectedAt, isNotNull);
      expect(service.snapshot.contact!.deviceId, 'bob');
      expect(service.snapshot.callId, callId);
    });

    test('重复的 answer 只应用一次', () async {
      final callId = await call();
      transport.receive(bob, CallSignal.answer(callId, 'remote-answer'));
      transport.receive(bob, CallSignal.answer(callId, 'remote-answer-2'));
      await phase(CallPhase.connecting);
      await _settle();
      expect(medias.single.log.where((entry) => entry.startsWith('acceptAnswer')), ['acceptAnswer:remote-answer']);
    });

    test('createOffer 期间产生的本端候选排在 offer 之后发出，之后的候选直接发出', () async {
      prepare = (media) => media.early = const [CallCandidate('early-1'), CallCandidate('early-2')];
      final callId = await call();
      await _until(() => transport.sent.length == 3, what: '两个候选发出');
      medias.single.emitCandidate('late');
      await _until(() => transport.sent.length == 4, what: '第三个候选发出');

      expect(transport.kinds, [
        CallSignal.kindOffer,
        CallSignal.kindCandidate,
        CallSignal.kindCandidate,
        CallSignal.kindCandidate,
      ]);
      expect(
        [for (final item in transport.ofKind(CallSignal.kindCandidate)) item.signal.candidate!.candidate],
        ['early-1', 'early-2', 'late'],
      );
      expect(transport.sent.every((item) => item.signal.callId == callId), isTrue);
      expect(transport.sent.every((item) => item.contact.sessionId == 'session-bob'), isTrue);
    });

    test('对方的候选在 answer 应用完之前先存着，之后按顺序加入', () async {
      final gate = Completer<void>();
      prepare = (media) => media.gate = gate;
      final callId = await call();
      final media = medias.single;

      transport.receive(bob, CallSignal.candidate(callId, const CallCandidate('r1')));
      await _settle();
      transport.receive(bob, CallSignal.answer(callId, 'remote-answer'));
      await _until(() => media.log.contains('acceptAnswer:remote-answer'), what: 'acceptAnswer');
      transport.receive(bob, CallSignal.candidate(callId, const CallCandidate('r2')));
      await _settle();
      expect(media.log.where((entry) => entry.startsWith('addCandidate')), isEmpty);

      gate.complete();
      await _until(() => media.log.length == 4, what: '候选加入');
      transport.receive(bob, CallSignal.candidate(callId, const CallCandidate('r3')));
      await _until(() => media.log.length == 5, what: '第三个候选加入');

      expect(media.log, [
        'createOffer',
        'acceptAnswer:remote-answer',
        'addCandidate:r1',
        'addCandidate:r2',
        'addCandidate:r3',
      ]);
    });

    for (final (reason, expected) in [
      (CallSignal.reasonReject, CallEndReason.rejected),
      (CallSignal.reasonBusy, CallEndReason.busy),
      (CallSignal.reasonFailed, CallEndReason.failed),
      (CallSignal.reasonHangup, CallEndReason.remoteHangup),
      ('something-new', CallEndReason.remoteHangup),
    ]) {
      test('对方结束（$reason）→ $expected', () async {
        final callId = await call();
        transport.receive(bob, CallSignal.end(callId, reason));
        await phase(CallPhase.ended);

        expect(service.snapshot.endReason, expected);
        expect(service.snapshot.contact!.deviceId, 'bob');
        expect(medias.single.closed, isTrue);
        // 对方已经结束，不用再回 end
        expect(transport.kinds, [CallSignal.kindOffer]);
      });
    }

    test('通话中对方挂断', () async {
      final callId = await call();
      transport.receive(bob, CallSignal.answer(callId, 'remote-answer'));
      await phase(CallPhase.connecting);
      medias.single.emitState(CallMediaState.connected);
      await phase(CallPhase.active);

      transport.receive(bob, CallSignal.end(callId, CallSignal.reasonHangup));
      await phase(CallPhase.ended);
      expect(service.snapshot.endReason, CallEndReason.remoteHangup);
      expect(medias.single.closed, isTrue);
    });

    test('自己取消：发 end(hangup)，以 hangup 结束', () async {
      final callId = await call();
      await service.hangup();

      expect(service.snapshot.phase, CallPhase.ended);
      expect(service.snapshot.endReason, CallEndReason.hangup);
      expect(medias.single.closed, isTrue);
      final end = transport.ofKind(CallSignal.kindEnd).single;
      expect(end.signal.callId, callId);
      expect(end.signal.reason, CallSignal.reasonHangup);
      expect(end.contact.sessionId, 'session-bob');
    });

    test('对方一直不接：超时后发 end(hangup)，以 timeout 结束', () async {
      await service.dispose();
      service = newService(ringTimeout: const Duration(milliseconds: 80));
      await call();
      await phase(CallPhase.ended);

      expect(service.snapshot.endReason, CallEndReason.timeout);
      expect(medias.single.closed, isTrue);
      expect(transport.ofKind(CallSignal.kindEnd).single.signal.reason, CallSignal.reasonHangup);
    });

    test('对方接听后响铃超时不再生效', () async {
      await service.dispose();
      service = newService(ringTimeout: const Duration(milliseconds: 80));
      final callId = await call();
      transport.receive(bob, CallSignal.answer(callId, 'remote-answer'));
      await phase(CallPhase.connecting);
      medias.single.emitState(CallMediaState.connected);
      await phase(CallPhase.active);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(service.snapshot.phase, CallPhase.active);
    });

    test('音频连接迟迟建不起来：超时后发 end(failed)，以 failed 结束', () async {
      await service.dispose();
      service = newService(connectTimeout: const Duration(milliseconds: 80));
      final callId = await call();
      transport.receive(bob, CallSignal.answer(callId, 'remote-answer'));
      await phase(CallPhase.connecting);
      await phase(CallPhase.ended);

      expect(service.snapshot.endReason, CallEndReason.failed);
      expect(medias.single.closed, isTrue);
      expect(transport.ofKind(CallSignal.kindEnd).single.signal.reason, CallSignal.reasonFailed);
    });

    test('callId 对不上、或别的联系人发来的信令一律忽略', () async {
      final callId = await call();
      transport.receive(bob, const CallSignal.answer('other-call', 'x'));
      transport.receive(carol, CallSignal.answer(callId, 'x'));
      transport.receive(bob, const CallSignal.end('other-call', CallSignal.reasonHangup));
      transport.receive(carol, CallSignal.end(callId, CallSignal.reasonHangup));
      transport.receive(carol, CallSignal.ringing(callId));
      transport.receive(bob, const CallSignal.candidate('other-call', CallCandidate('x')));
      transport.receiveRaw(bob, 'garbage');
      transport.receiveRaw(bob, '{"k":"answer","call":"$callId"}');
      await _settle();

      expect(service.snapshot.phase, CallPhase.outgoing);
      expect(service.snapshot.remoteRinging, isFalse);
      expect(medias.single.log, ['createOffer']);
      expect(transport.kinds, [CallSignal.kindOffer]);
    });

    test('已有通话时 start 抛 StateError；结束后可以直接再呼', () async {
      await call();
      await expectLater(service.start(carol), throwsStateError);
      expect(service.snapshot.contact!.deviceId, 'bob');

      await service.hangup();
      expect(service.snapshot.phase, CallPhase.ended);
      await service.start(carol);
      expect(service.snapshot.phase, CallPhase.outgoing);
      expect(service.snapshot.contact!.deviceId, 'carol');
      expect(service.snapshot.endReason, isNull);
      expect(medias, hasLength(2));
    });
  });

  group('来电', () {
    test('收到 offer：进入 incoming 并回 ringing，此时还不打开媒体', () async {
      await ring();

      final snapshot = service.snapshot;
      expect(snapshot.contact!.deviceId, 'bob');
      expect(snapshot.callId, 'in-1');
      expect(snapshot.isOutgoing, isFalse);
      expect(medias, isEmpty);
      final ringing = transport.sent.single;
      expect(ringing.signal.kind, CallSignal.kindRinging);
      expect(ringing.signal.callId, 'in-1');
      expect(ringing.contact.sessionId, 'session-bob');
    });

    test('接听：打开媒体、应用 offer、发出 answer，连上后进入 active', () async {
      await ring();
      await service.accept();

      expect(service.snapshot.phase, CallPhase.connecting);
      expect(medias.single.log, ['acceptOffer:remote-offer']);
      final answer = transport.ofKind(CallSignal.kindAnswer).single;
      expect(answer.signal.callId, 'in-1');
      expect(answer.signal.sdp, 'answer-sdp');
      expect(answer.contact.sessionId, 'session-bob');

      medias.single.emitState(CallMediaState.connected);
      await phase(CallPhase.active);
      expect(service.snapshot.connectedAt, isNotNull);
    });

    test('接听前收到的候选先存着，应用 offer 之后按顺序加入', () async {
      await ring();
      transport.receive(bob, const CallSignal.candidate('in-1', CallCandidate('r1')));
      transport.receive(bob, const CallSignal.candidate('in-1', CallCandidate('r2')));
      await _settle();
      expect(medias, isEmpty);

      await service.accept();
      await _until(() => medias.single.log.length == 3, what: '候选加入');
      transport.receive(bob, const CallSignal.candidate('in-1', CallCandidate('r3')));
      await _until(() => medias.single.log.length == 4, what: '第三个候选加入');

      expect(medias.single.log, [
        'acceptOffer:remote-offer',
        'addCandidate:r1',
        'addCandidate:r2',
        'addCandidate:r3',
      ]);
    });

    test('acceptOffer 期间产生的本端候选排在 answer 之后发出', () async {
      prepare = (media) => media.early = const [CallCandidate('early')];
      await ring();
      await service.accept();
      await _until(() => transport.sent.length == 3, what: '候选发出');

      expect(transport.kinds, [CallSignal.kindRinging, CallSignal.kindAnswer, CallSignal.kindCandidate]);
      expect(transport.sent.last.signal.callId, 'in-1');
    });

    test('拒接：发 end(reject)，以 declined 结束，不打开媒体', () async {
      await ring();
      await service.decline();

      expect(service.snapshot.phase, CallPhase.ended);
      expect(service.snapshot.endReason, CallEndReason.declined);
      expect(medias, isEmpty);
      final end = transport.ofKind(CallSignal.kindEnd).single;
      expect(end.signal.callId, 'in-1');
      expect(end.signal.reason, CallSignal.reasonReject);
    });

    test('响铃时对方先挂了：以 missed 结束', () async {
      await ring();
      transport.receive(bob, const CallSignal.end('in-1', CallSignal.reasonHangup));
      await phase(CallPhase.ended);

      expect(service.snapshot.endReason, CallEndReason.missed);
      expect(service.snapshot.contact!.deviceId, 'bob');
      expect(transport.kinds, [CallSignal.kindRinging]);
    });

    test('一直不接：超时后以 missed 结束，不发 end', () async {
      await service.dispose();
      service = newService(ringTimeout: const Duration(milliseconds: 80));
      await ring();
      await phase(CallPhase.ended);

      expect(service.snapshot.endReason, CallEndReason.missed);
      expect(transport.kinds, [CallSignal.kindRinging]);
    });

    test('接听时打不开麦克风：发 end(failed)，以 failed 结束', () async {
      prepare = (media) => media.acceptOfferError = StateError('no mic');
      await ring();
      await service.accept();

      expect(service.snapshot.phase, CallPhase.ended);
      expect(service.snapshot.endReason, CallEndReason.failed);
      expect(medias.single.closed, isTrue);
      expect(transport.ofKind(CallSignal.kindEnd).single.signal.reason, CallSignal.reasonFailed);
      expect(transport.ofKind(CallSignal.kindAnswer), isEmpty);
    });

    test('接通后自己挂断：发 end(hangup)', () async {
      await ring();
      await service.accept();
      medias.single.emitState(CallMediaState.connected);
      await phase(CallPhase.active);
      await service.hangup();

      expect(service.snapshot.endReason, CallEndReason.hangup);
      expect(medias.single.closed, isTrue);
      expect(transport.ofKind(CallSignal.kindEnd).single.signal.reason, CallSignal.reasonHangup);
    });

    test('通话中有别人打进来：回 end(busy)，当前通话不受影响', () async {
      await ring();
      transport.receive(carol, const CallSignal.offer('in-2', 'carol-offer'));
      await _until(() => transport.ofKind(CallSignal.kindEnd).isNotEmpty, what: 'busy');

      final busy = transport.ofKind(CallSignal.kindEnd).single;
      expect(busy.contact.sessionId, 'session-carol');
      expect(busy.signal.callId, 'in-2');
      expect(busy.signal.reason, CallSignal.reasonBusy);
      expect(service.snapshot.phase, CallPhase.incoming);
      expect(service.snapshot.contact!.deviceId, 'bob');
      expect(service.snapshot.callId, 'in-1');
    });

    test('呼出时对方也打过来（不同 callId）：回 end(busy)', () async {
      final callId = await call();
      transport.receive(bob, const CallSignal.offer('theirs', 'x'));
      await _until(() => transport.ofKind(CallSignal.kindEnd).isNotEmpty, what: 'busy');

      final busy = transport.ofKind(CallSignal.kindEnd).single;
      expect(busy.signal.callId, 'theirs');
      expect(busy.signal.reason, CallSignal.reasonBusy);
      expect(service.snapshot.phase, CallPhase.outgoing);
      expect(service.snapshot.callId, callId);
    });

    test('同一个 offer 重复到达：忽略，不重复回 ringing', () async {
      await ring();
      transport.receive(bob, const CallSignal.offer('in-1', 'remote-offer'));
      await _settle();
      expect(transport.kinds, [CallSignal.kindRinging]);
      expect(service.snapshot.phase, CallPhase.incoming);
    });

    test('已经结束的通话的 offer 被重放：忽略', () async {
      await ring();
      await service.decline();
      service.dismiss();
      final before = transport.sent.length;

      transport.receive(bob, const CallSignal.offer('in-1', 'remote-offer'));
      await _settle();
      expect(service.snapshot.phase, CallPhase.idle);
      expect(transport.sent, hasLength(before));
    });

    test('上一通结束后还没 dismiss 时，新的来电照常响铃', () async {
      await ring();
      await service.decline();
      expect(service.snapshot.phase, CallPhase.ended);

      await ring(callId: 'in-2', from: carol);
      expect(service.snapshot.contact!.deviceId, 'carol');
      expect(service.snapshot.callId, 'in-2');
      expect(service.snapshot.endReason, isNull);
    });

    test('空闲时收到 offer 以外的信令：忽略', () async {
      transport.receive(bob, const CallSignal.answer('x', 'sdp'));
      transport.receive(bob, const CallSignal.end('x', CallSignal.reasonHangup));
      transport.receive(bob, const CallSignal.candidate('x', CallCandidate('c')));
      transport.receive(bob, const CallSignal.ringing('x'));
      await _settle();
      expect(service.snapshot.phase, CallPhase.idle);
      expect(transport.sent, isEmpty);
    });
  });

  group('其它', () {
    test('状态不对时 accept / decline / hangup / dismiss / setMuted 都没有效果', () async {
      await service.accept();
      await service.decline();
      await service.hangup();
      service.dismiss();
      service.setMuted(true);
      expect(service.snapshot.phase, CallPhase.idle);
      expect(service.snapshot.muted, isFalse);
      expect(transport.sent, isEmpty);

      await call();
      await service.accept();
      await service.decline();
      service.dismiss();
      expect(service.snapshot.phase, CallPhase.outgoing);
      expect(transport.kinds, [CallSignal.kindOffer]);
    });

    test('静音传给媒体并反映在状态里；下一通通话从不静音开始', () async {
      await call();
      service.setMuted(true);
      expect(service.snapshot.muted, isTrue);
      expect(medias.single.muted, isTrue);
      service.setMuted(false);
      expect(service.snapshot.muted, isFalse);
      expect(medias.single.muted, isFalse);

      service.setMuted(true);
      await service.hangup();
      await service.start(bob);
      expect(service.snapshot.muted, isFalse);
    });

    test('dismiss：ended → idle', () async {
      await call();
      await service.hangup();
      service.dismiss();

      expect(service.snapshot.phase, CallPhase.idle);
      expect(service.snapshot.contact, isNull);
      expect(service.snapshot.callId, isNull);
      expect(service.snapshot.endReason, isNull);
    });

    test('changes 依次发出每个阶段', () async {
      final phases = <CallPhase>[];
      final subscription = service.changes.listen((snapshot) {
        if (phases.isEmpty || phases.last != snapshot.phase) phases.add(snapshot.phase);
      });

      final callId = await call();
      transport.receive(bob, CallSignal.answer(callId, 'remote-answer'));
      await phase(CallPhase.connecting);
      medias.single.emitState(CallMediaState.connected);
      await phase(CallPhase.active);
      await service.hangup();
      service.dismiss();
      await _settle();

      expect(phases, [
        CallPhase.outgoing,
        CallPhase.connecting,
        CallPhase.active,
        CallPhase.ended,
        CallPhase.idle,
      ]);
      await subscription.cancel();
    });

    test('结束之后迟到的信令和媒体事件不再改变状态', () async {
      final callId = await call();
      final media = medias.single;
      await service.hangup();

      transport.receive(bob, CallSignal.answer(callId, 'late'));
      transport.receive(bob, CallSignal.end(callId, CallSignal.reasonReject));
      media.emitState(CallMediaState.connected);
      media.emitCandidate('late');
      await _settle();

      expect(service.snapshot.phase, CallPhase.ended);
      expect(service.snapshot.endReason, CallEndReason.hangup);
      expect(media.log, ['createOffer']);
      expect(transport.kinds, [CallSignal.kindOffer, CallSignal.kindEnd]);
    });

    test('dispose：通话中则发 end(hangup) 并关闭媒体，之后不再处理信令', () async {
      await call();
      await service.dispose();

      expect(medias.single.closed, isTrue);
      expect(transport.ofKind(CallSignal.kindEnd).single.signal.reason, CallSignal.reasonHangup);

      final before = transport.sent.length;
      transport.receive(carol, const CallSignal.offer('after', 'x'));
      await _settle();
      expect(transport.sent, hasLength(before));
    });
  });
  test('媒体还在打开时再按一次接听：不会再建一个媒体，answer 只发一次', () async {
    await ring();
    final gate = Completer<void>();
    prepare = (media) => media.gate = gate;

    final first = service.accept();
    final second = service.accept();
    await _settle();
    expect(medias, hasLength(1));

    gate.complete();
    await Future.wait([first, second]);
    await phase(CallPhase.connecting);
    expect(medias, hasLength(1));
    expect(transport.ofKind(CallSignal.kindAnswer), hasLength(1));
  });

  group('通话中重连', () {
    /// 自己打给 Bob 并接通，返回 callId。
    Future<String> activeOutgoing() async {
      final callId = await call();
      transport.receive(bob, CallSignal.answer(callId, 'remote-answer'));
      await phase(CallPhase.connecting);
      medias.single.emitState(CallMediaState.connected);
      await phase(CallPhase.active);
      return callId;
    }

    /// Bob 打进来并接通，返回 callId。
    Future<String> activeIncoming() async {
      await ring();
      await service.accept();
      medias.single.emitState(CallMediaState.connected);
      await phase(CallPhase.active);
      return 'in-1';
    }

    Future<void> reconnecting(bool expected) => _until(
          () => service.snapshot.reconnecting == expected,
          what: 'reconnecting == $expected',
        );

    test('主叫：failed 后立刻 ICE 重启，应用 reanswer，重新连上后通话继续', () async {
      final callId = await activeOutgoing();
      final connectedAt = service.snapshot.connectedAt;
      final media = medias.single;

      media.emitState(CallMediaState.failed);
      await reconnecting(true);
      await _until(() => transport.ofKind(CallSignal.kindReoffer).isNotEmpty, what: '发出 reoffer');
      final reoffer = transport.ofKind(CallSignal.kindReoffer).single.signal;
      expect(reoffer.sdp, 'restart-offer-1');
      expect(reoffer.seq, 1);
      expect(service.snapshot.phase, CallPhase.active);

      transport.receive(bob, CallSignal.reanswer(callId, 'restart-answer', 1));
      await _until(() => media.log.contains('acceptAnswer:restart-answer'), what: '应用 reanswer');

      media.emitState(CallMediaState.connected);
      await reconnecting(false);
      expect(service.snapshot.phase, CallPhase.active);
      expect(service.snapshot.connectedAt, connectedAt);
      expect(media.closed, isFalse);
      expect(transport.ofKind(CallSignal.kindEnd), isEmpty);
    });

    test('disconnected 在宽限期内自己恢复：不做 ICE 重启', () async {
      service = newService(reconnectGrace: const Duration(milliseconds: 150));
      await activeOutgoing();
      final media = medias.single;

      media.emitState(CallMediaState.disconnected);
      await reconnecting(true);
      media.emitState(CallMediaState.connected);
      await reconnecting(false);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(media.log, isNot(contains('restartOffer')));
      expect(transport.ofKind(CallSignal.kindReoffer), isEmpty);
      expect(service.snapshot.phase, CallPhase.active);
    });

    test('disconnected 过了宽限期还没恢复：开始重启，并按间隔重试，seq 递增', () async {
      service = newService(
        reconnectGrace: const Duration(milliseconds: 30),
        reconnectRetry: const Duration(milliseconds: 60),
      );
      await activeOutgoing();

      medias.single.emitState(CallMediaState.disconnected);
      await _until(() => transport.ofKind(CallSignal.kindReoffer).length >= 2, what: '第二次 reoffer');
      final seqs = [for (final item in transport.ofKind(CallSignal.kindReoffer)) item.signal.seq];
      expect(seqs.take(2), [1, 2]);
    });

    test('重连超时：发 end(failed)，以 failed 结束', () async {
      service = newService(reconnectTimeout: const Duration(milliseconds: 80));
      await activeOutgoing();

      medias.single.emitState(CallMediaState.failed);
      await phase(CallPhase.ended);
      expect(service.snapshot.endReason, CallEndReason.failed);
      expect(medias.single.closed, isTrue);
      expect(transport.ofKind(CallSignal.kindEnd).single.signal.reason, CallSignal.reasonFailed);
    });

    test('过期的 reanswer（seq 对不上）被忽略', () async {
      final callId = await activeOutgoing();
      final media = medias.single;
      media.emitState(CallMediaState.failed);
      await _until(() => transport.ofKind(CallSignal.kindReoffer).isNotEmpty, what: '发出 reoffer');

      transport.receive(bob, CallSignal.reanswer(callId, 'stale-answer', 7));
      await _settle();
      expect(media.log, isNot(contains('acceptAnswer:stale-answer')));
    });

    test('主叫：收到被叫的 restart 请求就发 reoffer，自己媒体正常时不进入重连', () async {
      final callId = await activeOutgoing();
      transport.receive(bob, CallSignal.restart(callId));
      await _until(() => transport.ofKind(CallSignal.kindReoffer).isNotEmpty, what: '发出 reoffer');
      expect(service.snapshot.reconnecting, isFalse);
    });

    test('主叫：reanswer 应用之前到的对方候选先存着', () async {
      final callId = await activeOutgoing();
      final media = medias.single;
      media.emitState(CallMediaState.failed);
      await _until(() => transport.ofKind(CallSignal.kindReoffer).isNotEmpty, what: '发出 reoffer');

      media.gate = Completer<void>();
      transport.receive(bob, CallSignal.reanswer(callId, 'restart-answer', 1));
      transport.receive(bob, CallSignal.candidate(callId, const CallCandidate('new-cand')));
      await _settle();
      expect(media.log, isNot(contains('addCandidate:new-cand')));

      media.gate!.complete();
      await _until(() => media.log.contains('addCandidate:new-cand'), what: '候选加入');
      expect(
        media.log.indexOf('acceptAnswer:restart-answer'),
        lessThan(media.log.indexOf('addCandidate:new-cand')),
      );
    });

    test('主叫：reoffer 发出之前产生的本端候选排在 reoffer 之后发', () async {
      await activeOutgoing();
      final media = medias.single;
      media.early = const [CallCandidate('fresh-local')];
      final before = transport.sent.length;

      media.emitState(CallMediaState.failed);
      await _until(
        () => transport.sent.skip(before).any((item) => item.signal.kind == CallSignal.kindCandidate),
        what: '重启后的本端候选',
      );
      final kinds = [for (final item in transport.sent.skip(before)) item.signal.kind];
      expect(kinds.indexOf(CallSignal.kindReoffer), lessThan(kinds.indexOf(CallSignal.kindCandidate)));
    });

    test('被叫：failed 后请主叫重启；收到 reoffer 后应答并带回 seq', () async {
      final callId = await activeIncoming();
      final media = medias.single;

      media.emitState(CallMediaState.failed);
      await reconnecting(true);
      await _until(() => transport.ofKind(CallSignal.kindRestart).isNotEmpty, what: '发出 restart');
      expect(media.log, isNot(contains('restartOffer')));

      media.gate = Completer<void>();
      transport.receive(bob, CallSignal.reoffer(callId, 'restart-offer', 3));
      transport.receive(bob, CallSignal.candidate(callId, const CallCandidate('new-cand')));
      await _settle();
      expect(media.log, contains('acceptRestartOffer:restart-offer'));
      expect(media.log, isNot(contains('addCandidate:new-cand')));

      media.gate!.complete();
      await _until(() => transport.ofKind(CallSignal.kindReanswer).isNotEmpty, what: '发出 reanswer');
      final reanswer = transport.ofKind(CallSignal.kindReanswer).single.signal;
      expect(reanswer.sdp, 'restart-answer');
      expect(reanswer.seq, 3);
      await _until(() => media.log.contains('addCandidate:new-cand'), what: '候选加入');

      media.emitState(CallMediaState.connected);
      await reconnecting(false);
      expect(service.snapshot.phase, CallPhase.active);
    });

    test('被叫不发 reoffer；主叫不理会 reoffer', () async {
      final callId = await activeOutgoing();
      transport.receive(bob, CallSignal.reoffer(callId, 'x', 1));
      await _settle();
      expect(medias.single.log, isNot(contains('acceptRestartOffer:x')));
      expect(transport.ofKind(CallSignal.kindReanswer), isEmpty);
    });

    test('重连期间挂断：正常结束，不再重试', () async {
      service = newService(reconnectRetry: const Duration(milliseconds: 40));
      await activeOutgoing();
      medias.single.emitState(CallMediaState.failed);
      await reconnecting(true);

      await service.hangup();
      expect(service.snapshot.endReason, CallEndReason.hangup);
      final sent = transport.sent.length;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(transport.sent.length, sent);
    });

    test('重连时静音状态保留', () async {
      await activeOutgoing();
      service.setMuted(true);
      medias.single.emitState(CallMediaState.failed);
      await reconnecting(true);
      expect(service.snapshot.muted, isTrue);
      service.setMuted(false);
      expect(service.snapshot.reconnecting, isTrue);
    });
  });
}
