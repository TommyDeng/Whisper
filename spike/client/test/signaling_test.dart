import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_webrtc_spike/ice/candidate.dart';
import 'package:whisper_webrtc_spike/session/autorun_config.dart';
import 'package:whisper_webrtc_spike/session/rtc_config.dart';
import 'package:whisper_webrtc_spike/signaling/address.dart';
import 'package:whisper_webrtc_spike/signaling/events.dart';

void main() {
  test('builds a room websocket url and a health url', () {
    expect(buildSignalingUrl('ws://127.0.0.1:8787', 'AB12CD'), 'ws://127.0.0.1:8787/ws/AB12CD');
    expect(
      buildSignalingUrl('ws://127.0.0.1:8787', 'AB12CD', role: 'offerer'),
      'ws://127.0.0.1:8787/ws/AB12CD?role=offerer',
    );
    expect(buildSignalingUrl('ws://10.0.0.8:8787/ws/', 'room_1'), 'ws://10.0.0.8:8787/ws/room_1');
    expect(healthUrlFor('ws://10.0.0.8:8787'), 'http://10.0.0.8:8787/health');
    expect(healthUrlFor('wss://chat.example/ws'), 'https://chat.example/health');
    expect(() => buildSignalingUrl('http://127.0.0.1', 'AB12CD'), throwsFormatException);
    expect(() => buildSignalingUrl('ws://127.0.0.1', 'ab'), throwsFormatException);
  });

  test('room codes avoid ambiguous characters', () {
    final code = generateRoomCode(Random(1));
    expect(code, hasLength(6));
    expect(code, isNot(contains('0')));
    expect(code, isNot(contains('1')));
    expect(code, isNot(contains('I')));
    expect(code, isNot(contains('O')));
    expect(roomCodePattern.hasMatch(code), isTrue);
  });

  test('peer connection config leaves DTLS on and parses fingerprints', () {
    final config = buildPeerConnectionConfig();
    expect(configLeavesDtlsEnabled(config), isTrue);
    expect(config.containsKey('DtlsSrtpKeyAgreement'), isFalse);
    expect(config['iceServers'], [
      {'urls': 'stun:stun.cloudflare.com:3478'},
    ]);
    final sdp = 'v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\na=setup:actpass\r\n';
    expect(parseFingerprint(sdp).toString(), 'sha-256 AA:BB:CC');
    expect(configLeavesDtlsEnabled({'DtlsSrtpKeyAgreement': false}), isFalse);
  });

  test('parses relayed signaling events', () {
    expect(
      parseServerEvent('{"type":"welcome","role":"offerer","peerCount":1}'),
      isA<WelcomeEvent>().having((event) => event.role, 'role', 'offerer'),
    );
    expect(parseServerEvent('{"type":"peer-joined","peerCount":2}'), isA<PeerJoinedEvent>());
    final candidate = parseServerEvent(
      '{"type":"signal","kind":"candidate","candidate":"candidate:1 1 UDP 1 10.0.0.2 9 typ host","sdpMid":"0","sdpMLineIndex":0}',
    );
    expect(candidate, isA<SignalCandidateEvent>().having((event) => event.sdpMid, 'mid', '0'));
    expect(parseServerEvent('{"type":"signal","kind":"bye"}'), isA<SignalByeEvent>());
    expect(parseServerEvent('{'), isA<IgnoredEvent>());
  });

  test('autorun role and result paths are deterministic', () {
    expect(preferredAutorunRole(spikeRole: 'answerer', hasSpikeBytes: true), 'answerer');
    expect(preferredAutorunRole(hasSpikeBytes: true), 'offerer');
    expect(preferredAutorunRole(), isNull);
    expect(autorunResultPath(spikeResult: r'C:\temp\a.json', role: 'answerer'), r'C:\temp\a.json');
    expect(autorunResultPath(role: 'offerer'), 'spike-result-offerer.json');
    expect(autorunResultPath(role: 'answerer'), 'spike-result-answerer.json');
    expect(parseOnlyTier(null), isNull);
    expect(parseOnlyTier(''), isNull);
    expect(parseOnlyTier('ZeroTier'), PathTier.zerotier);
    expect(parseOnlyTier('lan'), PathTier.lan);
    expect(parseOnlyTier('srflx'), PathTier.srflx);
    expect(() => parseOnlyTier('relay'), throwsFormatException);
    expect(parseHoldSeconds(null), 0);
    expect(parseHoldSeconds('30'), 30);
    expect(() => parseHoldSeconds('-1'), throwsFormatException);
    expect(() => parseHoldSeconds('soon'), throwsFormatException);
  });
}
