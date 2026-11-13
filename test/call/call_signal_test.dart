import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/call/call_signal.dart';

void main() {
  test('每种信令编码后能原样解回', () {
    final offer = CallSignal.decode(const CallSignal.offer('c1', 'v=0\r\n').encode())!;
    expect((offer.kind, offer.callId, offer.sdp), (CallSignal.kindOffer, 'c1', 'v=0\r\n'));

    final answer = CallSignal.decode(const CallSignal.answer('c1', 'sdp').encode())!;
    expect((answer.kind, answer.sdp), (CallSignal.kindAnswer, 'sdp'));

    const candidate = CallCandidate('candidate:1 1 udp 1 10.0.0.2 5000 typ host', sdpMid: '0', sdpMLineIndex: 0);
    final decoded = CallSignal.decode(const CallSignal.candidate('c1', candidate).encode())!;
    expect(decoded.kind, CallSignal.kindCandidate);
    expect(decoded.candidate, candidate);

    final bare = CallSignal.decode(const CallSignal.candidate('c1', CallCandidate('x')).encode())!;
    expect(bare.candidate, const CallCandidate('x'));

    expect(CallSignal.decode(const CallSignal.ringing('c1').encode())!.kind, CallSignal.kindRinging);

    final end = CallSignal.decode(const CallSignal.end('c1', CallSignal.reasonBusy).encode())!;
    expect((end.kind, end.reason), (CallSignal.kindEnd, CallSignal.reasonBusy));
  });

  test('不合法的内容解析为 null', () {
    String json(Map<String, Object?> map) => jsonEncode(map);
    final bad = <String>[
      '',
      'not json',
      '[]',
      json({'k': 'offer', 'sdp': 'x'}),
      json({'k': 'offer', 'call': '', 'sdp': 'x'}),
      json({'k': 'offer', 'call': 'c' * 65, 'sdp': 'x'}),
      json({'k': 'offer', 'call': 'c1'}),
      json({'k': 'offer', 'call': 'c1', 'sdp': ''}),
      json({'k': 'offer', 'call': 'c1', 'sdp': 5}),
      json({'k': 'answer', 'call': 'c1', 'sdp': 'x' * (CallSignal.maxSdpChars + 1)}),
      json({'k': 'candidate', 'call': 'c1'}),
      json({'k': 'candidate', 'call': 'c1', 'cand': 'x' * (CallSignal.maxCandidateChars + 1)}),
      json({'k': 'candidate', 'call': 'c1', 'cand': 'x', 'mid': 3}),
      json({'k': 'candidate', 'call': 'c1', 'cand': 'x', 'line': '0'}),
      json({'k': 'candidate', 'call': 'c1', 'cand': 'x', 'line': -1}),
      json({'k': 'end', 'call': 'c1'}),
      json({'k': 'end', 'call': 'c1', 'reason': 1}),
      json({'k': 'video', 'call': 'c1'}),
      json({'call': 'c1'}),
    ];
    for (final body in bad) {
      expect(CallSignal.decode(body), isNull, reason: body.length > 80 ? body.substring(0, 80) : body);
    }
  });

  test('不认识的结束原因照常解开，多余的键忽略', () {
    final end = CallSignal.decode('{"k":"end","call":"c1","reason":"whatever","extra":1}')!;
    expect(end.reason, 'whatever');
  });
  group('通话中重连的信令', () {
    test('reoffer / reanswer / restart 编解码往返', () {
      final reoffer = CallSignal.decode(const CallSignal.reoffer('c1', 'sdp-o', 2).encode())!;
      expect(reoffer.kind, CallSignal.kindReoffer);
      expect(reoffer.callId, 'c1');
      expect(reoffer.sdp, 'sdp-o');
      expect(reoffer.seq, 2);

      final reanswer = CallSignal.decode(const CallSignal.reanswer('c1', 'sdp-a', 2).encode())!;
      expect(reanswer.kind, CallSignal.kindReanswer);
      expect(reanswer.sdp, 'sdp-a');
      expect(reanswer.seq, 2);

      final restart = CallSignal.decode(const CallSignal.restart('c1').encode())!;
      expect(restart.kind, CallSignal.kindRestart);
      expect(restart.sdp, isNull);
      expect(restart.seq, isNull);
    });

    test('缺 sdp、缺 seq 或 seq 越界时返回 null', () {
      expect(CallSignal.decode('{"k":"reoffer","call":"c1","seq":1}'), isNull);
      expect(CallSignal.decode('{"k":"reoffer","call":"c1","sdp":"x"}'), isNull);
      expect(CallSignal.decode('{"k":"reoffer","call":"c1","sdp":"x","seq":0}'), isNull);
      expect(CallSignal.decode('{"k":"reanswer","call":"c1","sdp":"x","seq":"1"}'), isNull);
      expect(CallSignal.decode('{"k":"reanswer","call":"c1","sdp":"x","seq":1000001}'), isNull);
    });
  });
}
