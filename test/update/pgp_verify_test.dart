import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/update/pgp_verify.dart';

void main() {
  // v1.0.5 Release 里真实的校验和文件和它的签名。
  final sums = File('test/update/fixtures/SHA256SUMS').readAsBytesSync();
  final signature = File('test/update/fixtures/SHA256SUMS.asc')
      .readAsStringSync();

  test('真实发布签名校验通过', () async {
    expect(
      await verifyDetachedSignature(
        armoredSignature: signature,
        data: sums,
        publicKey: kReleasePublicKey,
      ),
      isTrue,
    );
  });

  test('内容被改过一个字节就不通过', () async {
    final tampered = Uint8List.fromList(sums);
    tampered[10] ^= 0x01;
    expect(
      await verifyDetachedSignature(
        armoredSignature: signature,
        data: tampered,
        publicKey: kReleasePublicKey,
      ),
      isFalse,
    );
  });

  test('换一把公钥不通过', () async {
    final other = Uint8List.fromList(kReleasePublicKey);
    other[0] ^= 0xff;
    expect(
      await verifyDetachedSignature(
        armoredSignature: signature,
        data: sums,
        publicKey: other,
      ),
      isFalse,
    );
  });

  test('签名不是装甲格式或被截断时返回 false，不抛异常', () async {
    for (final bad in [
      '',
      'not a signature',
      '-----BEGIN PGP SIGNATURE-----\n\nAAAA\n-----END PGP SIGNATURE-----',
      signature.replaceFirst('iHUEABYK', 'iHUEABYL'),
    ]) {
      expect(
        await verifyDetachedSignature(
          armoredSignature: bad,
          data: sums,
          publicKey: kReleasePublicKey,
        ),
        isFalse,
        reason: bad,
      );
    }
  });

  test('内置公钥和仓库里公布的公钥文件一致', () {
    final lines = File('docs/whisper-release-public.asc')
        .readAsLinesSync()
        .map((line) => line.trim());
    final body = lines
        .skipWhile((line) => line.isNotEmpty)
        .where(
          (line) =>
              line.isNotEmpty && !line.startsWith('=') && !line.startsWith('-'),
        )
        .join();
    final packet = base64.decode(body);
    // 公钥包：版本 4、创建时间、算法 22、曲线 OID、0x40 开头的 32 字节公钥。
    expect(packet[0], 0x98);
    final key = packet.sublist(2, 2 + packet[1]);
    expect(key[0], 4);
    expect(key[5], 22);
    final point = key.sublist(7 + key[6] + 2);
    expect(point[0], 0x40);
    expect(point.sublist(1, 33), kReleasePublicKey);
  });
}
