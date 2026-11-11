import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/session/rtc_config.dart';

void main() {
  group('parseTurnServers', () {
    test('只取带凭据的 TURN 服务器', () {
      final body = jsonEncode({
        'ok': true,
        'iceServers': [
          {
            'urls': ['stun:stun.cloudflare.com:3478'],
          },
          {
            'urls': ['turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:443?transport=tcp'],
            'username': 'user',
            'credential': 'pass',
          },
          {
            'urls': ['stun:other.example:3478', 'turn:other.example:3478'],
            'username': 'u2',
            'credential': 'c2',
          },
          {
            'urls': ['turn:no-credential.example:3478'],
          },
        ],
      });

      expect(parseTurnServers(body), [
        {
          'urls': ['turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:443?transport=tcp'],
          'username': 'user',
          'credential': 'pass',
        },
        {
          'urls': ['turn:other.example:3478'],
          'username': 'u2',
          'credential': 'c2',
        },
      ]);
    });

    test('格式不对或服务端报错时返回空列表', () {
      expect(parseTurnServers('not json'), isEmpty);
      expect(parseTurnServers('[]'), isEmpty);
      expect(parseTurnServers('{"ok":false,"error":"turn-not-configured"}'), isEmpty);
      expect(parseTurnServers('{"iceServers":"x"}'), isEmpty);
      expect(parseTurnServers('{"iceServers":[1,{"urls":"turn:a","username":"u","credential":"c"}]}'), isEmpty);
    });
  });

  group('buildPeerConnectionConfig', () {
    test('默认不限制候选类型；forceRelay 时只用中继', () async {
      final normal = await buildPeerConnectionConfig();
      expect(normal.containsKey('iceTransportPolicy'), isFalse);

      final forced = await buildPeerConnectionConfig(forceRelay: true);
      expect(forced['iceTransportPolicy'], 'relay');
      expect(configLeavesDtlsEnabled(forced), isTrue);
    });
  });
}
