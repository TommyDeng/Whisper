// 耳语 E2EE 安全测试。
//
// 测试覆盖：
// - XChaCha20-Poly1305 加解密往返
// - 身份密钥生成
// - 安全码计算与验证
// - 文件分块加密与重传

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';

import 'package:whisper/e2ee/crypto.dart';
import 'package:whisper/identity/identity.dart';
import 'package:whisper/transfer/frames.dart';

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

  group('文件分块加密测试', () {
    test('分块编解码往返', () {
      final original = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final payloads = splitPayloads(original, 16);

      final encoded = <Uint8List>[];
      for (var i = 0; i < payloads.length; i++) {
        encoded.add(encodeChunkFrame(i, payloads[i]));
      }

      final decoded = <Uint8List>[];
      for (var i = 0; i < encoded.length; i++) {
        final frame = decodeChunkFrame(encoded[i]);
        expect(frame, isNotNull);
        decoded.add(frame!.payload);
      }

      final reassembled = Uint8List.fromList(decoded.expand((x) => x).toList());
      expect(reassembled, original);
    });

    test('分块重传检测缺失块', () {
      final original = Uint8List.fromList(List.generate(100, (i) => i));
      final payloads = splitPayloads(original, 16);
      final assembler = ChunkAssembler(size: original.length, chunkSize: 16);

      // 添加除第 2 块外的所有块
      for (var i = 0; i < payloads.length; i++) {
        if (i != 2) {
          final frame = encodeChunkFrame(i, payloads[i]);
          final decoded = decodeChunkFrame(frame)!;
          assembler.addFrame(decoded);
        }
      }

      expect(assembler.complete, isFalse);
      expect(assembler.missingSequences(), [2]);

      // 添加缺失的块
      final frame = encodeChunkFrame(2, payloads[2]);
      final decoded = decodeChunkFrame(frame)!;
      expect(assembler.addFrame(decoded), isTrue);
      expect(assembler.complete, isTrue);
    });
  });
}
