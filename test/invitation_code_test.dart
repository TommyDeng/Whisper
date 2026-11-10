// 邀请码模块的验收测试。
// 由编排者编写，定义 lib/pairing/invitation_code.dart 应有的行为；实现者不得修改本文件。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/pairing/invitation_code.dart';

const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// 与实现无关的参考 Base32 编码（无填充，末尾不足 5 位时低位补 0）。
String _base32(List<int> bytes) {
  final bitString = bytes.map((b) => b.toRadixString(2).padLeft(8, '0')).join();
  final padded = bitString.padRight((bitString.length + 4) ~/ 5 * 5, '0');
  final out = StringBuffer();
  for (var i = 0; i < padded.length; i += 5) {
    out.write(_alphabet[int.parse(padded.substring(i, i + 5), radix: 2)]);
  }
  return out.toString();
}

Uint8List _seq(int length, int start) =>
    Uint8List.fromList(List.generate(length, (i) => (start + i * 7) & 0xFF));

List<int> _rawBytes({int version = 1, int keyLen = 32, int tokenLen = 16, int expiry = 1900000000}) => [
      version,
      ..._seq(keyLen, 3),
      ..._seq(tokenLen, 200),
      (expiry >> 24) & 0xFF,
      (expiry >> 16) & 0xFF,
      (expiry >> 8) & 0xFF,
      expiry & 0xFF,
    ];

InvitationCode _sample({int expiry = 1900000000}) =>
    InvitationCode(publicKey: _seq(32, 3), token: _seq(16, 200), expiry: expiry);

void main() {
  group('编码', () {
    test('输出为 85 个字母表内字符，且与参考编码一致', () {
      final code = _sample().encode();
      expect(code, hasLength(85));
      expect(code.split('').every(_alphabet.contains), isTrue);
      expect(code, _base32(_rawBytes()));
    });

    test('编码后解码得到相同字段', () {
      final decoded = InvitationCode.decode(_sample().encode());
      expect(decoded, isNotNull);
      expect(decoded!.publicKey, _seq(32, 3));
      expect(decoded.token, _seq(16, 200));
      expect(decoded.expiry, 1900000000);
    });

    test('expiry 的边界值 0 和 0xFFFFFFFF 可以往返', () {
      for (final expiry in [0, 0xFFFFFFFF]) {
        final decoded = InvitationCode.decode(_sample(expiry: expiry).encode());
        expect(decoded?.expiry, expiry);
      }
    });

    test('公钥不是 32 字节时 encode 抛 ArgumentError', () {
      for (final len in [0, 31, 33]) {
        final bad = InvitationCode(publicKey: _seq(len, 3), token: _seq(16, 200), expiry: 1900000000);
        expect(bad.encode, throwsArgumentError, reason: 'publicKey 长度 $len');
      }
    });

    test('token 不是 16 字节时 encode 抛 ArgumentError', () {
      for (final len in [0, 15, 17]) {
        final bad = InvitationCode(publicKey: _seq(32, 3), token: _seq(len, 200), expiry: 1900000000);
        expect(bad.encode, throwsArgumentError, reason: 'token 长度 $len');
      }
    });

    test('expiry 超出无符号 32 位范围时 encode 抛 ArgumentError', () {
      for (final expiry in [-1, 0x100000000]) {
        expect(_sample(expiry: expiry).encode, throwsArgumentError, reason: 'expiry $expiry');
      }
    });
  });

  group('create', () {
    test('生成 16 字节 token、约 24 小时后过期，且可往返', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final created = InvitationCode.create(_seq(32, 3));
      expect(created.token, hasLength(16));
      expect(created.expiry, inInclusiveRange(now + 86400 - 5, now + 86400 + 5));
      expect(created.isExpired, isFalse);
      expect(InvitationCode.decode(created.encode())?.token, created.token);
    });

    test('两次生成的 token 不同', () {
      final a = InvitationCode.create(_seq(32, 3));
      final b = InvitationCode.create(_seq(32, 3));
      expect(a.token, isNot(b.token));
    });

    test('公钥不是 32 字节时抛 ArgumentError', () {
      for (final len in [0, 31, 33]) {
        expect(() => InvitationCode.create(_seq(len, 3)), throwsArgumentError, reason: '长度 $len');
      }
    });
  });

  group('解码：容许的输入形式', () {
    final code = _sample().encode();

    test('忽略大小写', () {
      expect(InvitationCode.decode(code.toLowerCase())?.expiry, 1900000000);
    });

    test('忽略首尾和中间的空白字符', () {
      final spaced = ' ${code.substring(0, 20)} ${code.substring(20, 50)}\n${code.substring(50)}\t\r\n';
      expect(InvitationCode.decode(spaced)?.token, _seq(16, 200));
    });

    test('忽略连字符分组', () {
      final groups = <String>[];
      for (var i = 0; i < code.length; i += 5) {
        groups.add(code.substring(i, i + 5));
      }
      expect(InvitationCode.decode(groups.join('-'))?.token, _seq(16, 200));
    });
  });

  group('解码：必须拒绝的输入', () {
    final code = _sample().encode();

    test('空串和只有分隔符的串', () {
      expect(InvitationCode.decode(''), isNull);
      expect(InvitationCode.decode('  - \n'), isNull);
    });

    test('版本号不是 1', () {
      expect(InvitationCode.decode(_base32(_rawBytes(version: 0))), isNull);
      expect(InvitationCode.decode(_base32(_rawBytes(version: 2))), isNull);
    });

    test('载荷长度不是 53 字节', () {
      expect(InvitationCode.decode(_base32(_rawBytes(keyLen: 31))), isNull);
      expect(InvitationCode.decode(_base32(_rawBytes(keyLen: 33))), isNull);
      expect(InvitationCode.decode(code.substring(0, 84)), isNull);
    });

    test('末尾多出字符', () {
      for (final extra in ['A', '2', 'AA', 'AAA']) {
        expect(InvitationCode.decode('$code$extra'), isNull, reason: '多出 "$extra"');
      }
    });

    test('混入字母表以外的字符（不能悄悄丢弃）', () {
      for (final junk in ['0', '1', 'I', 'O', 'i', 'o', '!', '_', '=', '中', '.']) {
        final mid = '${code.substring(0, 40)}$junk${code.substring(40)}';
        expect(InvitationCode.decode(mid), isNull, reason: '中间混入 "$junk"');
        expect(InvitationCode.decode('$code$junk'), isNull, reason: '末尾混入 "$junk"');
        expect(InvitationCode.decode('$junk$code'), isNull, reason: '开头混入 "$junk"');
      }
    });

    test('有效字符被替换成字母表以外的字符', () {
      final replaced = '${code.substring(0, 10)}0${code.substring(11)}';
      expect(InvitationCode.decode(replaced), isNull);
    });

    test('最后一个字符的补位不为 0（非规范编码）', () {
      // 53 字节 = 424 位，85 个字符 = 425 位，最后一个字符的最低位是补位，必须为 0。
      final lastIndex = _alphabet.indexOf(code[84]);
      expect(lastIndex.isEven, isTrue, reason: '测试前提：规范编码的补位为 0');
      final nonCanonical = code.substring(0, 84) + _alphabet[lastIndex + 1];
      expect(InvitationCode.decode(nonCanonical), isNull);
    });
  });

  group('过期判断', () {
    test('过去的时间戳已过期，未来的未过期', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(_sample(expiry: now - 10).isExpired, isTrue);
      expect(_sample(expiry: now + 3600).isExpired, isFalse);
      expect(_sample(expiry: now + 3600).ttl, inInclusiveRange(3595, 3600));
    });
  });
}
