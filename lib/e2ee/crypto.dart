/// 耳语 E2EE 加密模块。
///
/// 设计（按架构文档 Stage 1 §4）：
/// 1. 双方各生成 X25519 身份密钥对
/// 2. 交换公钥，通过 X25519 计算共享秘密（直接得到 256-bit 对称密钥）
/// 3. 用 XChaCha20-Poly1305 加密消息（192-bit 随机 nonce，无碰撞顾虑）
/// 4. 消息填充至固定长度区间，减少长度泄露
/// 5. 附加数据 (AAD) 含会话 ID + 序号，防重放/重排

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 会话加密工具
class SessionCrypto {
  /// XChaCha20-Poly1305 nonce 长度（192 bits = 24 bytes）
  static const int nonceLength = 24;

  /// 填充块大小（1 KiB）
  static const int paddingBlockSize = 1024;

  /// 最大消息负载大小（256 KiB）
  static const int maxPayloadSize = 256 * 1024;

  /// 生成 X25519 身份密钥对
  static Future<SimpleKeyPair> generateIdentityKeyPair() async {
    final x25519 = X25519();
    return await x25519.newKeyPair();
  }

  /// 从本地私钥和对方公钥派生会话加密密钥（X25519 共享秘密）
  static Future<SecretKey> deriveSessionKey({
    required SimpleKeyPair localKeyPair,
    required SimplePublicKey remotePublicKey,
  }) async {
    final x25519 = X25519();
    return await x25519.sharedSecretKey(
      keyPair: localKeyPair,
      remotePublicKey: remotePublicKey,
    );
  }

  /// 加密一条文本消息
  static Future<EncryptedMessage> encrypt({
    required SecretKey secretKey,
    required String sessionId,
    required int sequenceNumber,
    required String plaintext,
  }) async {
    final algorithm = Xchacha20.poly1305Aead();
    final nonce = algorithm.newNonce();

    // 构建附加数据 (AAD)：会话 ID + 序号
    final aad = utf8.encode('$sessionId:$sequenceNumber');

    // 消息填充：减少长度泄露
    final paddedPayload = _padMessage(plaintext);

    final secretBox = await algorithm.encrypt(
      utf8.encode(paddedPayload),
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
    );

    return EncryptedMessage(
      nonce: Uint8List.fromList(secretBox.nonce),
      ciphertext: Uint8List.fromList(secretBox.cipherText),
      mac: Uint8List.fromList(secretBox.mac.bytes),
      sequenceNumber: sequenceNumber,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 解密一条文本消息
  static Future<String> decrypt({
    required SecretKey secretKey,
    required String sessionId,
    required int sequenceNumber,
    required EncryptedMessage encrypted,
  }) async {
    final algorithm = Xchacha20.poly1305Aead();

    // 构建附加数据 (AAD)
    final aad = utf8.encode('$sessionId:$sequenceNumber');

    final secretBox = SecretBox(
      encrypted.ciphertext,
      nonce: encrypted.nonce,
      mac: Mac(encrypted.mac),
    );

    final decrypted = await algorithm.decrypt(
      secretBox,
      secretKey: secretKey,
      aad: aad,
    );

    final plaintext = utf8.decode(decrypted);
    return _unpadMessage(plaintext);
  }

  /// 将消息填充到固定长度区间，减少长度泄露
  static String _padMessage(String plaintext) {
    final bytes = utf8.encode(plaintext);
    if (bytes.isEmpty) return plaintext;

    // 填充到 paddingBlockSize 的整数倍，上限 maxPayloadSize
    final paddedLength = ((bytes.length ~/ paddingBlockSize) + 1) *
        paddingBlockSize;
    final targetLength =
        paddedLength.clamp(paddingBlockSize, maxPayloadSize);

    if (bytes.length >= targetLength) return plaintext;

    final padding = List<int>.filled(targetLength - bytes.length, 0);
    return utf8.decode(Uint8List.fromList([...bytes, ...padding]));
  }

  /// 移除填充，还原原始消息
  static String _unpadMessage(String paddedPlaintext) {
    final bytes = utf8.encode(paddedPlaintext);
    int lastNonZero = bytes.length - 1;
    while (lastNonZero >= 0 && bytes[lastNonZero] == 0) {
      lastNonZero--;
    }
    if (lastNonZero < 0) return '';
    return utf8.decode(Uint8List.fromList(bytes.sublist(0, lastNonZero + 1)));
  }
}

/// 加密消息封装格式（用于信令传输）
class EncryptedMessage {
  const EncryptedMessage({
    required this.nonce,
    required this.ciphertext,
    required this.mac,
    required this.sequenceNumber,
    required this.timestamp,
  });

  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List mac;
  final int sequenceNumber;
  final int timestamp;

  /// 序列化为 JSON
  Map<String, dynamic> toJson() => {
    'nonce': base64Url.encode(nonce),
    'ciphertext': base64Url.encode(ciphertext),
    'mac': base64Url.encode(mac),
    'seq': sequenceNumber,
    'ts': timestamp,
  };

  /// 从 JSON 反序列化
  static EncryptedMessage fromJson(Map<String, dynamic> json) =>
      EncryptedMessage(
        nonce: Uint8List.fromList(base64Url.decode(json['nonce'] as String)),
        ciphertext:
            Uint8List.fromList(base64Url.decode(json['ciphertext'] as String)),
        mac: Uint8List.fromList(base64Url.decode(json['mac'] as String)),
        sequenceNumber: json['seq'] as int,
        timestamp: json['ts'] as int,
      );
}
