/// 校验发布文件的 OpenPGP 分离签名（`SHA256SUMS.asc`）。
///
/// 只支持发布流程实际产生的那一种：v4 签名、Ed25519（算法 22）、对二进制文件签名、
/// 摘要 SHA-256 或 SHA-512。别的一律当作校验失败，不做兼容。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

/// 发布签名公钥（Ed25519，32 字节），与 `docs/whisper-release-public.asc` 一致。
/// 指纹 A40E233E59519F99D67177B373A32114054E9B10。换密钥时这里要跟着改。
final Uint8List kReleasePublicKey = _hex(
  '3bae37be13a8285eaa8e56f31d3739fa79869defa9ff3b4b03b6ab4c4b866d49',
);

Uint8List _hex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

/// [armoredSignature] 是不是 [publicKey] 对 [data] 的有效签名。
/// 格式不对、算法不支持、签名不符都返回 false，不抛异常。
Future<bool> verifyDetachedSignature({
  required String armoredSignature,
  required List<int> data,
  required List<int> publicKey,
}) async {
  try {
    final body = _signaturePacketBody(_dearmor(armoredSignature));
    // 版本 4、签名类型 0（二进制文件）、公钥算法 22（EdDSA）。
    if (body.length < 6 || body[0] != 4 || body[1] != 0 || body[2] != 22) {
      return false;
    }
    final hash = switch (body[3]) {
      8 => hashes.sha256,
      10 => hashes.sha512,
      _ => null,
    };
    if (hash == null) return false;

    final hashedLength = (body[4] << 8) | body[5];
    final hashedEnd = 6 + hashedLength;
    var offset = hashedEnd;
    final unhashedLength = (body[offset] << 8) | body[offset + 1];
    offset += 2 + unhashedLength;
    offset += 2; // 摘要的前两个字节，只是快速检查用
    final r = _readMpi(body, offset);
    final s = _readMpi(body, offset + 2 + r.length);

    // 签的是：文件内容 + 签名包里被保护的那一段 + 固定的结尾。
    final digest = hash.convert([
      ...data,
      ...body.sublist(0, hashedEnd),
      0x04,
      0xff,
      (hashedEnd >> 24) & 0xff,
      (hashedEnd >> 16) & 0xff,
      (hashedEnd >> 8) & 0xff,
      hashedEnd & 0xff,
    ]).bytes;

    return await Ed25519().verify(
      digest,
      signature: Signature([
        ..._leftPad(r, 32),
        ..._leftPad(s, 32),
      ], publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

/// 去掉 ASCII 装甲，得到二进制包。
Uint8List _dearmor(String armored) {
  final lines = const LineSplitter().convert(armored.trim());
  final begin = lines.indexWhere((line) => line.startsWith('-----BEGIN PGP'));
  final end = lines.indexWhere((line) => line.startsWith('-----END PGP'));
  if (begin < 0 || end <= begin) throw const FormatException('不是装甲格式');
  // 头部字段和正文之间隔一个空行；`=` 开头的是校验和。
  var start = begin + 1;
  final blank = lines.indexWhere((line) => line.trim().isEmpty, start);
  if (blank >= 0 && blank < end) start = blank + 1;
  final payload = StringBuffer();
  for (final line in lines.sublist(start, end)) {
    final text = line.trim();
    if (text.isEmpty || text.startsWith('=')) continue;
    payload.write(text);
  }
  return base64.decode(payload.toString());
}

/// 取出第一个包的内容，要求它是签名包（tag 2）。
Uint8List _signaturePacketBody(Uint8List packet) {
  final first = packet[0];
  if (first & 0x80 == 0) throw const FormatException('不是 OpenPGP 包');
  int tag;
  int length;
  int offset;
  if (first & 0x40 != 0) {
    // 新格式
    tag = first & 0x3f;
    final l = packet[1];
    if (l < 192) {
      length = l;
      offset = 2;
    } else if (l < 224) {
      length = ((l - 192) << 8) + packet[2] + 192;
      offset = 3;
    } else {
      throw const FormatException('不支持的包长度');
    }
  } else {
    // 旧格式
    tag = (first >> 2) & 0x0f;
    switch (first & 0x03) {
      case 0:
        length = packet[1];
        offset = 2;
      case 1:
        length = (packet[1] << 8) | packet[2];
        offset = 3;
      default:
        throw const FormatException('不支持的包长度');
    }
  }
  if (tag != 2) throw const FormatException('不是签名包');
  return Uint8List.sublistView(packet, offset, offset + length);
}

/// 读一个多精度整数：两字节的位数，后面是数值。
Uint8List _readMpi(Uint8List bytes, int offset) {
  final bits = (bytes[offset] << 8) | bytes[offset + 1];
  final length = (bits + 7) >> 3;
  return Uint8List.sublistView(bytes, offset + 2, offset + 2 + length);
}

List<int> _leftPad(List<int> bytes, int length) {
  if (bytes.length > length) throw const FormatException('整数过长');
  return [...List.filled(length - bytes.length, 0), ...bytes];
}
