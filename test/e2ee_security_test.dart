// 耳语 E2EE 安全测试。
//
// 测试覆盖：
// - XChaCha20-Poly1305 加解密往返
// - 身份密钥生成
// - 安全码计算与验证

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';

import 'package:whisper/e2ee/crypto.dart';
import 'package:whisper/identity/identity.dart';

void main() {
  group('E2EE 加解密测试', () {
    test('XChaCha20-Poly1305 加解密往返', () async {
      final x25519 = X25519();
      final keyPairA = await x25519.newKeyPair();
      final keyPairB = await x25519.newKeyPair();
      final publicKeyB = await keyPairB.extractPublicKey();

      final sessionKey = await SessionCrypto.deriveSessionKey(
        localKeyPair: keyPairA,
        remotePublicKey: publicKeyB,
      );

      final plaintext = '耳语测试消息：Hello, Whisper!';
      final encrypted = await SessionCrypto.encrypt(
        secretKey: sessionKey,
        sessionId: 'test-session-1',
        sequenceNumber: 0,
        plaintext: plaintext,
      );

      final decrypted = await SessionCrypto.decrypt(
        secretKey: sessionKey,
        sessionId: 'test-session-1',
        sequenceNumber: 0,
        encrypted: encrypted,
      );

      expect(decrypted, plaintext);
    });

    test('错误的会话ID导致解密失败', () async {
      final x25519 = X25519();
      final keyPairA = await x25519.newKeyPair();
      final keyPairB = await x25519.newKeyPair();
      final publicKeyB = await keyPairB.extractPublicKey();

      final sessionKey = await SessionCrypto.deriveSessionKey(
        localKeyPair: keyPairA,
        remotePublicKey: publicKeyB,
      );

      final encrypted = await SessionCrypto.encrypt(
        secretKey: sessionKey,
        sessionId: 'session-1',
        sequenceNumber: 0,
        plaintext: '秘密消息',
      );

      // 使用错误的sessionId（AAD不匹配）应该解密失败
      expect(
        () async {
          await SessionCrypto.decrypt(
            secretKey: sessionKey,
            sessionId: 'wrong-session',
            sequenceNumber: 0,
            encrypted: encrypted,
          );
        },
        throwsA(isA<Exception>()),
      );
    });
  });

  group('身份密钥测试', () {
    test('X25519 密钥对生成', () async {
      final x25519 = X25519();
      final keyPair = await x25519.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      expect(publicKey, isNotNull);
      expect(publicKey.bytes.length, 32);
    });

    test('IdentityKeyPair 构造', () {
      final keyPair = IdentityKeyPair(
        x25519PublicKey: Uint8List(32),
        x25519PrivateKey: Uint8List(32),
        ed25519PublicKey: Uint8List(32),
        ed25519PrivateKey: Uint8List(32),
      );
      expect(keyPair.ed25519PublicKey.length, 32);
      expect(keyPair.x25519PublicKeyBase64.isNotEmpty, isTrue);
    });
  });

  group('安全码测试', () {
    test('安全码计算确定性', () {
      final code1 = SafetyCode.compute('AAAA', 'BBBB');
      final code2 = SafetyCode.compute('BBBB', 'AAAA');

      // 顺序不应影响结果
      expect(code1, code2);
      expect(code1.split(' ').length, 12);
      expect(code1.split(' ').every((s) => s.length == 5), isTrue);
    });

    test('安全码验证格式', () {
      final code = SafetyCode.compute('AAAA', 'BBBB');
      expect(SafetyCode.isValid(code), isTrue);
      expect(SafetyCode.isValid('invalid'), isFalse);
    });
  });
}
