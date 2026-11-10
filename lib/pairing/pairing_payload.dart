/// 配对载荷的加解密：`pair-request` 和 `pair-response` 里的 payload。
///
/// 流程见 docs/relay-protocol.md 第三节，密码学构造见 docs/pairing-payload.md。
/// 中继只看得到这里产出的不透明字符串。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 一方告诉对方的身份信息。
class PairProfile {
  const PairProfile({
    required this.x25519PublicKey,
    required this.ed25519PublicKey,
    required this.name,
  });

  /// X25519 公钥，32 字节。
  final Uint8List x25519PublicKey;

  /// Ed25519 公钥，32 字节。
  final Uint8List ed25519PublicKey;

  /// 自报的显示名，最多 [PairingPayload.maxNameLength] 个字符，可以为空。
  final String name;
}

/// 邀请人批准后给加入者的内容。
class PairAcceptance {
  const PairAcceptance({required this.sessionId, required this.inviter});

  /// 之后双方连接 `/session/<sessionId>` 用的 ID。
  final String sessionId;

  /// 邀请人的身份信息。其中 x25519PublicKey 一定等于邀请码里的公钥。
  final PairProfile inviter;
}

/// 载荷无法解开或内容不合法。不携带任何密钥或明文。
class PairingPayloadException implements Exception {
  const PairingPayloadException(this.reason);

  /// 简短的原因码，例如 `malformed`、`decrypt-failed`、`bad-profile`。
  final String reason;

  @override
  String toString() => 'PairingPayloadException($reason)';
}

const String _kRequestLabel = 'whisper/pair-request/v1';
const String _kResponseLabel = 'whisper/pair-response/v1';
final List<int> _kRequestLabelBytes = utf8.encode(_kRequestLabel);
final List<int> _kResponseLabelBytes = utf8.encode(_kResponseLabel);
final RegExp _sessionIdRegex = RegExp(r'^[A-Za-z0-9_-]{22,64}$');

String _b64uEncode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _b64uDecode(String text) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(text)));

Future<SecretKey> _hkdf(List<int> ikm, List<int> salt, List<int> info) async =>
    Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: SecretKey(ikm), nonce: salt, info: info);

Map<String, dynamic> _decodeEnvelope(String payload) {
  final bytes = _b64uDecode(payload);
  final object = jsonDecode(utf8.decode(bytes));
  if (object is! Map<String, dynamic>) {
    throw const PairingPayloadException('malformed');
  }
  return object;
}

Map<String, dynamic> _decodeJsonMap(String source) {
  final object = jsonDecode(source);
  if (object is! Map<String, dynamic>) {
    throw const PairingPayloadException('bad-profile');
  }
  return object;
}

Uint8List _requireKey32(Map<String, dynamic> map, String field) {
  final raw = map[field];
  if (raw is! String) {
    throw const PairingPayloadException('bad-profile');
  }
  final bytes = _b64uDecode(raw);
  if (bytes.length != 32) {
    throw const PairingPayloadException('bad-profile');
  }
  return bytes;
}

String _requireName(Map<String, dynamic> map) {
  final raw = map['name'];
  if (raw is! String) {
    throw const PairingPayloadException('bad-profile');
  }
  if (raw.length > PairingPayload.maxNameLength) {
    throw const PairingPayloadException('bad-profile');
  }
  return raw;
}

String _requireSessionId(Map<String, dynamic> map) {
  final raw = map['sessionId'];
  if (raw is! String) {
    throw const PairingPayloadException('bad-profile');
  }
  if (!_sessionIdRegex.hasMatch(raw)) {
    throw const PairingPayloadException('bad-profile');
  }
  return raw;
}

Uint8List _requireEnvelopeBytes(
  Map<String, dynamic> map,
  String field,
  int length,
) {
  final raw = map[field];
  if (raw is! String) {
    throw const PairingPayloadException('malformed');
  }
  final bytes = _b64uDecode(raw);
  if (bytes.length != length) {
    throw const PairingPayloadException('malformed');
  }
  return bytes;
}

Uint8List _requireEnvelopeCt(Map<String, dynamic> map) {
  final raw = map['ct'];
  if (raw is! String) {
    throw const PairingPayloadException('malformed');
  }
  final bytes = _b64uDecode(raw);
  if (bytes.isEmpty) {
    throw const PairingPayloadException('malformed');
  }
  return bytes;
}

class PairingPayload {
  PairingPayload._();

  static const int maxNameLength = 64;

  /// 生成新的会话 ID：32 个随机字节（`Random.secure()`）的 base64url，无填充，43 个字符。
  static String newSessionId() {
    final bytes = Uint8List(32);
    final random = Random.secure();
    for (var i = 0; i < 32; i++) {
      bytes[i] = random.nextInt(256);
    }
    return _b64uEncode(bytes);
  }

  /// 加入者：把自己的身份信息加密给邀请人。
  static Future<String> sealRequest({
    required Uint8List inviterPublicKey,
    required Uint8List token,
    required PairProfile joiner,
  }) async {
    if (inviterPublicKey.length != 32) {
      throw ArgumentError('inviterPublicKey 必须是 32 字节');
    }
    if (token.length != 16) {
      throw ArgumentError('token 必须是 16 字节');
    }
    if (joiner.name.length > maxNameLength) {
      throw ArgumentError('name 不得超过 $maxNameLength 个字符');
    }

    final x25519 = X25519();
    final ephemeral = await x25519.newKeyPair();
    final ephemeralPublic = Uint8List.fromList(
      (await ephemeral.extractPublicKey()).bytes,
    );
    final shared = await x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(inviterPublicKey, type: KeyPairType.x25519),
    );
    final key = await _hkdf(
      await shared.extractBytes(),
      token,
      [..._kRequestLabelBytes, ...ephemeralPublic, ...inviterPublicKey],
    );
    final plaintext = utf8.encode(jsonEncode(<String, dynamic>{
      'x25519': _b64uEncode(joiner.x25519PublicKey),
      'ed25519': _b64uEncode(joiner.ed25519PublicKey),
      'name': joiner.name,
    }));
    final cipher = Xchacha20.poly1305Aead();
    final nonce = cipher.newNonce();
    final box = await cipher.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: _kRequestLabelBytes,
    );
    final envelope = <String, dynamic>{
      'v': 1,
      'epk': _b64uEncode(ephemeralPublic),
      'nonce': _b64uEncode(box.nonce),
      'ct': _b64uEncode(box.cipherText),
      'mac': _b64uEncode(box.mac.bytes),
    };
    return _b64uEncode(utf8.encode(jsonEncode(envelope)));
  }

  /// 邀请人：解开配对请求，得到加入者的身份信息。
  static Future<PairProfile> openRequest({
    required String payload,
    required Uint8List inviterPrivateKey,
    required Uint8List token,
  }) async {
    try {
      final envelope = _decodeEnvelope(payload);
      if (envelope['v'] != 1) {
        throw const PairingPayloadException('malformed');
      }
      final epk = _requireEnvelopeBytes(envelope, 'epk', 32);
      final nonce = _requireEnvelopeBytes(envelope, 'nonce', 24);
      final mac = _requireEnvelopeBytes(envelope, 'mac', 16);
      final ct = _requireEnvelopeCt(envelope);

      final x25519 = X25519();
      final keyPair = await x25519.newKeyPairFromSeed(inviterPrivateKey);
      final inviterPublic = Uint8List.fromList(
        (await keyPair.extractPublicKey()).bytes,
      );
      final secret = await x25519.sharedSecretKey(
        keyPair: keyPair,
        remotePublicKey: SimplePublicKey(epk, type: KeyPairType.x25519),
      );
      final key = await _hkdf(
        await secret.extractBytes(),
        token,
        [..._kRequestLabelBytes, ...epk, ...inviterPublic],
      );
      final box = SecretBox(ct, nonce: nonce, mac: Mac(mac));
      final plaintext = await Xchacha20.poly1305Aead()
          .decrypt(box, secretKey: key, aad: _kRequestLabelBytes);
      final map = _decodeJsonMap(utf8.decode(plaintext));
      return PairProfile(
        x25519PublicKey: _requireKey32(map, 'x25519'),
        ed25519PublicKey: _requireKey32(map, 'ed25519'),
        name: _requireName(map),
      );
    } on PairingPayloadException {
      rethrow;
    } catch (_) {
      throw const PairingPayloadException('malformed');
    }
  }

  /// 邀请人：批准后，把会话 ID 和自己的身份信息加密给加入者。
  static Future<String> sealResponse({
    required Uint8List inviterPrivateKey,
    required Uint8List joinerPublicKey,
    required Uint8List token,
    required String sessionId,
    required PairProfile inviter,
  }) async {
    if (!_sessionIdRegex.hasMatch(sessionId)) {
      throw ArgumentError(r'sessionId 不符合 ^[A-Za-z0-9_-]{22,64}$');
    }
    if (joinerPublicKey.length != 32) {
      throw ArgumentError('joinerPublicKey 必须是 32 字节');
    }
    if (token.length != 16) {
      throw ArgumentError('token 必须是 16 字节');
    }
    if (inviter.name.length > maxNameLength) {
      throw ArgumentError('name 不得超过 $maxNameLength 个字符');
    }

    final x25519 = X25519();
    final keyPair = await x25519.newKeyPairFromSeed(inviterPrivateKey);
    final inviterPublic = Uint8List.fromList(
      (await keyPair.extractPublicKey()).bytes,
    );
    final secret = await x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(joinerPublicKey, type: KeyPairType.x25519),
    );
    final key = await _hkdf(
      await secret.extractBytes(),
      token,
      [..._kResponseLabelBytes, ...inviterPublic, ...joinerPublicKey],
    );
    final plaintext = utf8.encode(jsonEncode(<String, dynamic>{
      'sessionId': sessionId,
      'ed25519': _b64uEncode(inviter.ed25519PublicKey),
      'name': inviter.name,
    }));
    final cipher = Xchacha20.poly1305Aead();
    final nonce = cipher.newNonce();
    final box = await cipher.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: _kResponseLabelBytes,
    );
    final envelope = <String, dynamic>{
      'v': 1,
      'nonce': _b64uEncode(box.nonce),
      'ct': _b64uEncode(box.cipherText),
      'mac': _b64uEncode(box.mac.bytes),
    };
    return _b64uEncode(utf8.encode(jsonEncode(envelope)));
  }

  /// 加入者：解开批准响应。
  static Future<PairAcceptance> openResponse({
    required String payload,
    required Uint8List joinerPrivateKey,
    required Uint8List inviterPublicKey,
    required Uint8List token,
  }) async {
    try {
      final envelope = _decodeEnvelope(payload);
      if (envelope['v'] != 1) {
        throw const PairingPayloadException('malformed');
      }
      final nonce = _requireEnvelopeBytes(envelope, 'nonce', 24);
      final mac = _requireEnvelopeBytes(envelope, 'mac', 16);
      final ct = _requireEnvelopeCt(envelope);

      final x25519 = X25519();
      final keyPair = await x25519.newKeyPairFromSeed(joinerPrivateKey);
      final joinerPublic = Uint8List.fromList(
        (await keyPair.extractPublicKey()).bytes,
      );
      final secret = await x25519.sharedSecretKey(
        keyPair: keyPair,
        remotePublicKey: SimplePublicKey(inviterPublicKey, type: KeyPairType.x25519),
      );
      final key = await _hkdf(
        await secret.extractBytes(),
        token,
        [..._kResponseLabelBytes, ...inviterPublicKey, ...joinerPublic],
      );
      final box = SecretBox(ct, nonce: nonce, mac: Mac(mac));
      final plaintext = await Xchacha20.poly1305Aead()
          .decrypt(box, secretKey: key, aad: _kResponseLabelBytes);
      final map = _decodeJsonMap(utf8.decode(plaintext));
      return PairAcceptance(
        sessionId: _requireSessionId(map),
        inviter: PairProfile(
          x25519PublicKey: inviterPublicKey,
          ed25519PublicKey: _requireKey32(map, 'ed25519'),
          name: _requireName(map),
        ),
      );
    } on PairingPayloadException {
      rethrow;
    } catch (_) {
      throw const PairingPayloadException('malformed');
    }
  }
}
