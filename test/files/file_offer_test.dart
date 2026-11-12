import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/files/file_cipher.dart';
import 'package:whisper/files/file_offer.dart';

void main() {
  FileOffer sample({String name = '报告.pdf', int size = 12345}) => FileOffer(
    fileId: FileOffer.newFileId(),
    name: name,
    size: size,
    keys: FileKeys.random(),
    hash: Uint8List.fromList(List.generate(32, (i) => i)),
  );

  Map<String, dynamic> json(FileOffer offer) =>
      jsonDecode(offer.encode()) as Map<String, dynamic>;

  test('newFileId 是 43 个 URL 安全字符，互不相同', () {
    final a = FileOffer.newFileId();
    final b = FileOffer.newFileId();
    expect(a, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(a, isNot(b));
  });

  test('encode / decode 往返', () {
    final offer = sample();
    final decoded = FileOffer.decode(offer.encode());
    expect(decoded.fileId, offer.fileId);
    expect(decoded.name, '报告.pdf');
    expect(decoded.size, 12345);
    expect(decoded.keys.key, offer.keys.key);
    expect(decoded.keys.noncePrefix, offer.keys.noncePrefix);
    expect(decoded.hash, offer.hash);
    expect(json(offer).keys.toSet(), {
      'v',
      'id',
      'name',
      'size',
      'key',
      'np',
      'hash',
    });
  });

  test('最长的文件名编码后不超过消息正文上限', () {
    final offer = sample(
      name: '文' * FileOffer.maxNameLength,
      size: FileCipher.maxFileBytes,
    );
    expect(utf8.encode(offer.encode()).length, lessThanOrEqualTo(2048));
  });

  test('decode 拒绝不合格的内容', () {
    final good = json(sample());
    String with_(String key, Object? value) =>
        jsonEncode({...good, key: value});
    final bad = <String, String>{
      '不是 JSON': 'not json',
      '不是对象': '[1,2]',
      '版本不对': with_('v', 2),
      'id 太短': with_('id', 'abc'),
      'id 有非法字符': with_('id', '${'a' * 42}/'),
      'id 不是字符串': with_('id', 5),
      '文件名为空': with_('name', ''),
      '文件名过长': with_('name', 'a' * 256),
      '大小为负': with_('size', -1),
      '大小超限': with_('size', FileCipher.maxFileBytes + 1),
      '大小不是整数': with_('size', '12'),
      '密钥长度不对': with_('key', base64Url.encode(List.filled(31, 0))),
      'noncePrefix 长度不对': with_('np', base64Url.encode(List.filled(15, 0))),
      '哈希长度不对': with_('hash', base64Url.encode(List.filled(33, 0))),
      '密钥不是 base64': with_('key', '***'),
      '缺少哈希': with_('hash', null),
    };
    for (final entry in bad.entries) {
      expect(
        () => FileOffer.decode(entry.value),
        throwsFormatException,
        reason: entry.key,
      );
    }
  });

  test('构造时同样校验', () {
    expect(() => sample(name: ''), throwsFormatException);
    expect(() => sample(size: -1), throwsFormatException);
    expect(
      () => FileOffer(
        fileId: 'short',
        name: 'a',
        size: 1,
        keys: FileKeys.random(),
        hash: Uint8List(32),
      ),
      throwsFormatException,
    );
  });

  test('safeName 去掉路径和危险字符', () {
    const cases = {
      'report.pdf': 'report.pdf',
      '../../etc/passwd': 'passwd',
      r'C:\Users\x\evil.exe': 'evil.exe',
      '/abs/path/': 'file',
      '..': 'file',
      '.': 'file',
      'a\u0000b\nc.txt': 'abc.txt',
      'what?*<>|":.txt': 'what.txt',
      'trailing. . ': 'trailing',
      '  spaced name.txt': 'spaced name.txt',
      '照片 01.jpg': '照片 01.jpg',
      '.bashrc': '.bashrc',
    };
    cases.forEach((name, expected) {
      expect(FileOffer.sanitizeName(name), expected, reason: name);
    });
    expect(sample(name: 'dir/x.txt').safeName, 'x.txt');
  });

  test('via 缺省为中转，编码不带 via 字段', () {
    final offer = sample(size: FileCipher.maxFileBytes);
    expect(offer.via, FileTransferVia.r2);
    expect(offer.isDirect, isFalse);
    expect(json(offer).containsKey('via'), isFalse);
    expect(FileOffer.decode(offer.encode()).via, FileTransferVia.r2);
  });

  test('via 为 direct 时允许超过中转上限', () {
    final size = FileCipher.maxFileBytes + 1;
    final offer = FileOffer(
      fileId: FileOffer.newFileId(),
      name: '电影.mkv',
      size: size,
      keys: FileKeys.random(),
      hash: Uint8List.fromList(List.generate(32, (i) => i)),
      via: FileTransferVia.direct,
    );
    expect(offer.isDirect, isTrue);
    expect(json(offer)['via'], 'direct');
    final decoded = FileOffer.decode(offer.encode());
    expect(decoded.via, FileTransferVia.direct);
    expect(decoded.size, size);
  });

  test('via 为 direct 时仍拒绝超过 100 GiB 或不合格的 via', () {
    expect(
      () => FileOffer(
        fileId: FileOffer.newFileId(),
        name: 'a.bin',
        size: FileCipher.maxDirectFileBytes + 1,
        keys: FileKeys.random(),
        hash: Uint8List(32),
        via: FileTransferVia.direct,
      ),
      throwsFormatException,
    );
    final good = json(sample());
    expect(
      () => FileOffer.decode(jsonEncode({...good, 'via': 'turn'})),
      throwsFormatException,
    );
    expect(
      () => FileOffer.decode(
        jsonEncode({
          ...good,
          'via': 'direct',
          'size': FileCipher.maxDirectFileBytes + 1,
        }),
      ),
      throwsFormatException,
    );
    // 没有 via 时仍然按中转上限拒绝
    expect(
      () => FileOffer.decode(
        jsonEncode({...good, 'size': FileCipher.maxFileBytes + 1}),
      ),
      throwsFormatException,
    );
  });
}
