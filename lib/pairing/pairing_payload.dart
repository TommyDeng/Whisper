/// 配对载荷的加解密：`pair-request` 和 `pair-response` 里的 payload。
///
/// 流程见 docs/relay-protocol.md 第三节，密码学构造见 docs/pairing-payload.md。
/// 中继只看得到这里产出的不透明字符串。
library;

import 'dart:typed_data';

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

class PairingPayload {
  PairingPayload._();

  static const int maxNameLength = 64;

  /// 生成新的会话 ID：32 个随机字节（`Random.secure()`）的 base64url，无填充，43 个字符。
  static String newSessionId() => throw UnimplementedError();

  /// 加入者：把自己的身份信息加密给邀请人。
  static Future<String> sealRequest({
    required Uint8List inviterPublicKey,
    required Uint8List token,
    required PairProfile joiner,
  }) =>
      throw UnimplementedError();

  /// 邀请人：解开配对请求，得到加入者的身份信息。
  static Future<PairProfile> openRequest({
    required String payload,
    required Uint8List inviterPrivateKey,
    required Uint8List token,
  }) =>
      throw UnimplementedError();

  /// 邀请人：批准后，把会话 ID 和自己的身份信息加密给加入者。
  static Future<String> sealResponse({
    required Uint8List inviterPrivateKey,
    required Uint8List joinerPublicKey,
    required Uint8List token,
    required String sessionId,
    required PairProfile inviter,
  }) =>
      throw UnimplementedError();

  /// 加入者：解开批准响应。
  static Future<PairAcceptance> openResponse({
    required String payload,
    required Uint8List joinerPrivateKey,
    required Uint8List inviterPublicKey,
    required Uint8List token,
  }) =>
      throw UnimplementedError();
}
