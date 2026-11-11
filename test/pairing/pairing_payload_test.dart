import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/pairing/pairing_payload.dart';

String _b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _unb64u(String text) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(text)));

Uint8List _bytes(int length, int seed) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 7 + seed) & 0xff));

class _Keys {
  _Keys(this.privateKey, this.publicKey);
  final Uint8List privateKey;
  final Uint8List publicKey;

  static Future<_Keys> fromSeed(int seed) async {
    final privateKey = _bytes(32, seed);
    final pair = await X25519().newKeyPairFromSeed(privateKey);
    final publicKey = await pair.extractPublicKey();
    return _Keys(privateKey, Uint8List.fromList(publicKey.bytes));
  }
}

Future<List<int>> _shared(Uint8List privateKey, Uint8List publicKey) async {
  final x25519 = X25519();
  final secret = await x25519.sharedSecretKey(
    keyPair: await x25519.newKeyPairFromSeed(privateKey),
    remotePublicKey: SimplePublicKey(publicKey, type: KeyPairType.x25519),
  );
  return secret.extractBytes();
}

Future<SecretKey> _hkdf(List<int> ikm, List<int> salt, List<int> info) =>
    Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: SecretKey(ikm), nonce: salt, info: info);

Map<String, dynamic> _envelope(String payload) =>
    jsonDecode(utf8.decode(_unb64u(payload))) as Map<String, dynamic>;

String _reseal(Map<String, dynamic> envelope) => _b64u(utf8.encode(jsonEncode(envelope)));

/// 把信封里某个 base64url 字段的第一个字节翻转一位。
String _flip(String payload, String field) {
  final envelope = _envelope(payload);
  final bytes = _unb64u(envelope[field] as String);
  bytes[0] ^= 0x01;
  envelope[field] = _b64u(bytes);
  return _reseal(envelope);
}

/// 用文档里的构造独立加密一份 pair-request，明文由调用方给出。
Future<String> _referenceRequest({
  required Uint8List inviterPublicKey,
  required Uint8List token,
  required Object? plaintext,
  int ephemeralSeed = 99,
}) async {
  final ephemeral = await _Keys.fromSeed(ephemeralSeed);
  const label = 'whisper/pair-request/v1';
  final key = await _hkdf(
    await _shared(ephemeral.privateKey, inviterPublicKey),
    token,
    [...utf8.encode(label), ...ephemeral.publicKey, ...inviterPublicKey],
  );
  final cipher = Xchacha20.poly1305Aead();
  final box = await cipher.encrypt(
    utf8.encode(jsonEncode(plaintext)),
    secretKey: key,
    nonce: cipher.newNonce(),
    aad: utf8.encode(label),
  );
  return _reseal({
    'v': 1,
    'epk': _b64u(ephemeral.publicKey),
    'nonce': _b64u(box.nonce),
    'ct': _b64u(box.cipherText),
    'mac': _b64u(box.mac.bytes),
  });
}

/// 用文档里的构造独立加密一份 pair-response。
Future<String> _referenceResponse({
  required _Keys inviter,
  required Uint8List joinerPublicKey,
  required Uint8List token,
  required Object? plaintext,
}) async {
  const label = 'whisper/pair-response/v1';
  final key = await _hkdf(
    await _shared(inviter.privateKey, joinerPublicKey),
    token,
    [...utf8.encode(label), ...inviter.publicKey, ...joinerPublicKey],
  );
  final cipher = Xchacha20.poly1305Aead();
  final box = await cipher.encrypt(
    utf8.encode(jsonEncode(plaintext)),
    secretKey: key,
    nonce: cipher.newNonce(),
    aad: utf8.encode(label),
  );
  return _reseal({
    'v': 1,
    'nonce': _b64u(box.nonce),
    'ct': _b64u(box.cipherText),
    'mac': _b64u(box.mac.bytes),
  });
}

Matcher _fails = throwsA(isA<PairingPayloadException>());

void main() {
  late _Keys inviter;
  late _Keys joiner;
  late _Keys stranger;
  final token = _bytes(16, 3);
  final otherToken = _bytes(16, 4);
  const sessionId = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ';

  late PairProfile joinerProfile;
  late PairProfile inviterProfile;

  setUp(() async {
    inviter = await _Keys.fromSeed(1);
    joiner = await _Keys.fromSeed(2);
    stranger = await _Keys.fromSeed(5);
    joinerProfile = PairProfile(
      x25519PublicKey: joiner.publicKey,
      ed25519PublicKey: _bytes(32, 20),
      name: '小明',
    );
    inviterProfile = PairProfile(
      x25519PublicKey: inviter.publicKey,
      ed25519PublicKey: _bytes(32, 10),
      name: 'Tommy',
    );
  });

  group('newSessionId', () {
    test('43 个 base64url 字符，每次不同', () {
      final ids = {for (var i = 0; i < 20; i++) PairingPayload.newSessionId()};
      expect(ids, hasLength(20));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      }
    });
  });

  group('pair-request', () {
    Future<String> seal() => PairingPayload.sealRequest(
          inviterPublicKey: inviter.publicKey,
          token: token,
          joiner: joinerProfile,
        );

    Future<PairProfile> open(String payload, {Uint8List? privateKey, Uint8List? withToken}) =>
        PairingPayload.openRequest(
          payload: payload,
          inviterPrivateKey: privateKey ?? inviter.privateKey,
          token: withToken ?? token,
        );

    test('邀请人能解开，得到加入者的身份信息', () async {
      final profile = await open(await seal());
      expect(profile.x25519PublicKey, joiner.publicKey);
      expect(profile.ed25519PublicKey, joinerProfile.ed25519PublicKey);
      expect(profile.name, '小明');
    });

    test('信封结构符合文档，且在中继的配对载荷上限之内', () async {
      final payload = await seal();
      expect(payload, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(payload.length, lessThan(8192));

      final envelope = _envelope(payload);
      expect(envelope.keys.toSet(), {'v', 'epk', 'nonce', 'ct', 'mac'});
      expect(envelope['v'], 1);
      expect(_unb64u(envelope['epk'] as String), hasLength(32));
      expect(_unb64u(envelope['nonce'] as String), hasLength(24));
      expect(_unb64u(envelope['mac'] as String), hasLength(16));
      for (final field in ['epk', 'nonce', 'ct', 'mac']) {
        expect(envelope[field], isNot(contains('=')), reason: '$field 应无填充');
      }
    });

    test('每次使用新的临时密钥和 nonce', () async {
      final a = _envelope(await seal());
      final b = _envelope(await seal());
      expect(a['epk'], isNot(b['epk']));
      expect(a['nonce'], isNot(b['nonce']));
      expect(a['ct'], isNot(b['ct']));
      expect(a['epk'], isNot(_b64u(joiner.publicKey)), reason: '不能把静态密钥当临时密钥用');
    });

    test('密钥派生与文档一致：sealRequest 的输出能用文档构造独立解开', () async {
      final envelope = _envelope(await seal());
      final epk = _unb64u(envelope['epk'] as String);
      const label = 'whisper/pair-request/v1';
      final key = await _hkdf(
        await _shared(inviter.privateKey, epk),
        token,
        [...utf8.encode(label), ...epk, ...inviter.publicKey],
      );
      final clear = await Xchacha20.poly1305Aead().decrypt(
        SecretBox(
          _unb64u(envelope['ct'] as String),
          nonce: _unb64u(envelope['nonce'] as String),
          mac: Mac(_unb64u(envelope['mac'] as String)),
        ),
        secretKey: key,
        aad: utf8.encode(label),
      );
      expect(jsonDecode(utf8.decode(clear)), {
        'x25519': _b64u(joiner.publicKey),
        'ed25519': _b64u(joinerProfile.ed25519PublicKey),
        'name': '小明',
      });
    });

    test('密钥派生与文档一致：openRequest 能解开按文档独立构造的请求', () async {
      final payload = await _referenceRequest(
        inviterPublicKey: inviter.publicKey,
        token: token,
        plaintext: {
          'x25519': _b64u(joiner.publicKey),
          'ed25519': _b64u(joinerProfile.ed25519PublicKey),
          'name': '',
        },
      );
      final profile = await open(payload);
      expect(profile.x25519PublicKey, joiner.publicKey);
      expect(profile.name, '');
    });

    test('私钥不对或 token 不对都解不开', () async {
      final payload = await seal();
      await expectLater(open(payload, privateKey: stranger.privateKey), _fails);
      await expectLater(open(payload, withToken: otherToken), _fails);
    });

    test('任何一个字段被篡改都解不开', () async {
      final payload = await seal();
      for (final field in ['epk', 'nonce', 'ct', 'mac']) {
        await expectLater(open(_flip(payload, field)), _fails, reason: field);
      }
    });

    test('格式不对的载荷报 PairingPayloadException，而不是别的异常', () async {
      final good = _envelope(await seal());
      final cases = <String>[
        '',
        '!!!not-base64!!!',
        _b64u(utf8.encode('not json')),
        _b64u(utf8.encode('[1,2]')),
        _reseal({...good, 'v': 2}),
        _reseal({...good}..remove('epk')),
        _reseal({...good, 'epk': _b64u(_bytes(31, 1))}),
        _reseal({...good, 'nonce': _b64u(_bytes(12, 1))}),
        _reseal({...good, 'mac': _b64u(_bytes(8, 1))}),
        _reseal({...good, 'ct': ''}),
        _reseal({...good, 'ct': 5}),
      ];
      for (final payload in cases) {
        await expectLater(open(payload), _fails, reason: payload);
      }
    });

    test('明文内容不合法时拒绝', () async {
      final ed = _b64u(_bytes(32, 20));
      final x = _b64u(joiner.publicKey);
      final badPlaintexts = <Object?>[
        {'x25519': _b64u(_bytes(31, 1)), 'ed25519': ed, 'name': 'n'},
        {'x25519': x, 'ed25519': _b64u(_bytes(33, 1)), 'name': 'n'},
        {'x25519': x, 'ed25519': ed},
        {'x25519': x, 'ed25519': ed, 'name': 7},
        {'x25519': x, 'ed25519': ed, 'name': 'n' * 65},
        {'x25519': 12, 'ed25519': ed, 'name': 'n'},
        ['not', 'an', 'object'],
      ];
      for (final plaintext in badPlaintexts) {
        final payload = await _referenceRequest(
          inviterPublicKey: inviter.publicKey,
          token: token,
          plaintext: plaintext,
        );
        await expectLater(open(payload), _fails, reason: jsonEncode(plaintext));
      }

      final ok = await _referenceRequest(
        inviterPublicKey: inviter.publicKey,
        token: token,
        plaintext: {'x25519': x, 'ed25519': ed, 'name': 'n' * 64},
      );
      expect((await open(ok)).name, 'n' * 64);
    });

    test('sealRequest 拒绝不合法的输入', () async {
      Future<String> sealWith({Uint8List? key, Uint8List? withToken, PairProfile? profile}) =>
          PairingPayload.sealRequest(
            inviterPublicKey: key ?? inviter.publicKey,
            token: withToken ?? token,
            joiner: profile ?? joinerProfile,
          );
      await expectLater(sealWith(key: _bytes(31, 1)), throwsArgumentError);
      await expectLater(sealWith(withToken: _bytes(15, 1)), throwsArgumentError);
      await expectLater(
        sealWith(
          profile: PairProfile(
            x25519PublicKey: joiner.publicKey,
            ed25519PublicKey: _bytes(32, 20),
            name: 'n' * 65,
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('pair-response', () {
    Future<String> seal({String id = sessionId}) => PairingPayload.sealResponse(
          inviterPrivateKey: inviter.privateKey,
          joinerPublicKey: joiner.publicKey,
          token: token,
          sessionId: id,
          inviter: inviterProfile,
        );

    Future<PairAcceptance> open(
      String payload, {
      Uint8List? privateKey,
      Uint8List? inviterPublicKey,
      Uint8List? withToken,
    }) =>
        PairingPayload.openResponse(
          payload: payload,
          joinerPrivateKey: privateKey ?? joiner.privateKey,
          inviterPublicKey: inviterPublicKey ?? inviter.publicKey,
          token: withToken ?? token,
        );

    test('加入者能解开，得到会话 ID 和邀请人的身份信息', () async {
      final acceptance = await open(await seal());
      expect(acceptance.sessionId, sessionId);
      expect(acceptance.inviter.x25519PublicKey, inviter.publicKey);
      expect(acceptance.inviter.ed25519PublicKey, inviterProfile.ed25519PublicKey);
      expect(acceptance.inviter.name, 'Tommy');
    });

    test('信封结构符合文档', () async {
      final payload = await seal();
      expect(payload, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(payload.length, lessThan(8192));
      final envelope = _envelope(payload);
      expect(envelope.keys.toSet(), {'v', 'nonce', 'ct', 'mac'});
      expect(envelope['v'], 1);
      expect(_unb64u(envelope['nonce'] as String), hasLength(24));
      expect(_unb64u(envelope['mac'] as String), hasLength(16));
      expect(_envelope(await seal())['nonce'], isNot(envelope['nonce']));
    });

    test('密钥派生与文档一致：openResponse 能解开按文档独立构造的响应', () async {
      final payload = await _referenceResponse(
        inviter: inviter,
        joinerPublicKey: joiner.publicKey,
        token: token,
        plaintext: {
          'sessionId': sessionId,
          'ed25519': _b64u(inviterProfile.ed25519PublicKey),
          'name': 'ref',
        },
      );
      final acceptance = await open(payload);
      expect(acceptance.sessionId, sessionId);
      expect(acceptance.inviter.name, 'ref');
      expect(acceptance.inviter.x25519PublicKey, inviter.publicKey);
    });

    test('冒充者解不开；邀请人公钥或 token 不对也解不开', () async {
      final payload = await seal();
      await expectLater(open(payload, privateKey: stranger.privateKey), _fails);
      await expectLater(open(payload, inviterPublicKey: stranger.publicKey), _fails);
      await expectLater(open(payload, withToken: otherToken), _fails);
    });

    test('不是邀请人发出的响应被拒绝', () async {
      final forged = await _referenceResponse(
        inviter: stranger,
        joinerPublicKey: joiner.publicKey,
        token: token,
        plaintext: {
          'sessionId': sessionId,
          'ed25519': _b64u(_bytes(32, 10)),
          'name': 'evil',
        },
      );
      await expectLater(open(forged), _fails);
    });

    test('篡改或格式不对的载荷被拒绝', () async {
      final payload = await seal();
      for (final field in ['nonce', 'ct', 'mac']) {
        await expectLater(open(_flip(payload, field)), _fails, reason: field);
      }
      final good = _envelope(payload);
      for (final bad in <String>[
        '',
        '***',
        _b64u(utf8.encode('{')),
        _reseal({...good, 'v': 0}),
        _reseal({...good}..remove('mac')),
        _reseal({...good, 'nonce': _b64u(_bytes(23, 1))}),
      ]) {
        await expectLater(open(bad), _fails, reason: bad);
      }
    });

    test('明文内容不合法时拒绝', () async {
      final ed = _b64u(_bytes(32, 10));
      final badPlaintexts = <Object?>[
        {'sessionId': 'too-short', 'ed25519': ed, 'name': 'n'},
        {'sessionId': 'has space ${'a' * 30}', 'ed25519': ed, 'name': 'n'},
        {'sessionId': 'a' * 65, 'ed25519': ed, 'name': 'n'},
        {'sessionId': 5, 'ed25519': ed, 'name': 'n'},
        {'ed25519': ed, 'name': 'n'},
        {'sessionId': sessionId, 'ed25519': _b64u(_bytes(16, 1)), 'name': 'n'},
        {'sessionId': sessionId, 'ed25519': ed, 'name': 'n' * 65},
        {'sessionId': sessionId, 'ed25519': ed},
      ];
      for (final plaintext in badPlaintexts) {
        final payload = await _referenceResponse(
          inviter: inviter,
          joinerPublicKey: joiner.publicKey,
          token: token,
          plaintext: plaintext,
        );
        await expectLater(open(payload), _fails, reason: jsonEncode(plaintext));
      }
    });

    test('sealResponse 拒绝不合法的输入', () async {
      await expectLater(seal(id: 'short'), throwsArgumentError);
      await expectLater(
        PairingPayload.sealResponse(
          inviterPrivateKey: inviter.privateKey,
          joinerPublicKey: _bytes(31, 1),
          token: token,
          sessionId: sessionId,
          inviter: inviterProfile,
        ),
        throwsArgumentError,
      );
    });
  });

  test('完整往返：请求 → 批准 → 响应，双方得到同一个会话 ID', () async {
    final request = await PairingPayload.sealRequest(
      inviterPublicKey: inviter.publicKey,
      token: token,
      joiner: joinerProfile,
    );
    final seenJoiner = await PairingPayload.openRequest(
      payload: request,
      inviterPrivateKey: inviter.privateKey,
      token: token,
    );
    final id = PairingPayload.newSessionId();
    final response = await PairingPayload.sealResponse(
      inviterPrivateKey: inviter.privateKey,
      joinerPublicKey: seenJoiner.x25519PublicKey,
      token: token,
      sessionId: id,
      inviter: inviterProfile,
    );
    final acceptance = await PairingPayload.openResponse(
      payload: response,
      joinerPrivateKey: joiner.privateKey,
      inviterPublicKey: inviter.publicKey,
      token: token,
    );
    expect(acceptance.sessionId, id);
    expect(acceptance.inviter.name, 'Tommy');
  });
}
