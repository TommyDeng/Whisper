import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/files/file_cipher.dart';

const _mib = FileCipher.chunkSize;

/// 可重复的伪随机内容，避免各块内容相同。
Uint8List _pattern(int length, {int seed = 1}) {
  final bytes = Uint8List(length);
  var x = seed;
  for (var i = 0; i < length; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    bytes[i] = x >> 16;
  }
  return bytes;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('whisper_file_cipher_');
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  Future<File> source(Uint8List content, [String name = 'source.bin']) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(content, flush: true);
    return file;
  }

  Future<List<Uint8List>> sealAll(File file, FileKeys keys) async {
    final count = FileCipher.chunkCount(await file.length());
    return [for (var i = 0; i < count; i++) await FileCipher.sealChunk(file, keys, i)];
  }

  group('FileKeys', () {
    test('长度不对抛 ArgumentError', () {
      expect(
        () => FileKeys(key: Uint8List(31), noncePrefix: Uint8List(16)),
        throwsArgumentError,
      );
      expect(
        () => FileKeys(key: Uint8List(33), noncePrefix: Uint8List(16)),
        throwsArgumentError,
      );
      expect(
        () => FileKeys(key: Uint8List(32), noncePrefix: Uint8List(15)),
        throwsArgumentError,
      );
      expect(
        () => FileKeys(key: Uint8List(32), noncePrefix: Uint8List(24)),
        throwsArgumentError,
      );
      final keys = FileKeys(key: Uint8List(32), noncePrefix: Uint8List(16));
      expect(keys.key, hasLength(32));
      expect(keys.noncePrefix, hasLength(16));
    });

    test('random 生成合格且互不相同的密钥', () {
      final a = FileKeys.random();
      final b = FileKeys.random();
      expect(a.key, hasLength(32));
      expect(a.noncePrefix, hasLength(16));
      expect(a.key, isNot(equals(b.key)));
      expect(a.noncePrefix, isNot(equals(b.noncePrefix)));
    });
  });

  group('FileCipher.chunkCount', () {
    test('按 1 MiB 向上取整，空文件 1 块', () {
      expect(FileCipher.chunkCount(0), 1);
      expect(FileCipher.chunkCount(1), 1);
      expect(FileCipher.chunkCount(_mib - 1), 1);
      expect(FileCipher.chunkCount(_mib), 1);
      expect(FileCipher.chunkCount(_mib + 1), 2);
      expect(FileCipher.chunkCount(FileCipher.maxFileBytes), 100);
    });

    test('负数抛 ArgumentError', () {
      expect(() => FileCipher.chunkCount(-1), throwsArgumentError);
    });
  });

  group('FileCipher.hashFile', () {
    test('与一次性 BLAKE2b-256 结果一致', () async {
      final content = _pattern(_mib + 4321);
      final file = await source(content);
      final expected = await Blake2b(hashLengthInBytes: 32).hash(content);
      final actual = await FileCipher.hashFile(file);
      expect(actual, hasLength(32));
      expect(actual, expected.bytes);
    });

    test('空文件', () async {
      final file = await source(Uint8List(0));
      final expected = await Blake2b(hashLengthInBytes: 32).hash(const []);
      expect(await FileCipher.hashFile(file), expected.bytes);
    });
  });

  group('sealChunk / openChunk', () {
    Future<void> roundTrip(int size, List<int> expectedClearLengths) async {
      final content = _pattern(size);
      final file = await source(content);
      final keys = FileKeys.random();
      final count = FileCipher.chunkCount(size);
      expect(count, expectedClearLengths.length);

      final out = BytesBuilder(copy: false);
      for (var i = 0; i < count; i++) {
        final sealed = await FileCipher.sealChunk(file, keys, i);
        expect(sealed.length, expectedClearLengths[i] + FileCipher.tagLength);
        final clear = await FileCipher.openChunk(sealed, keys, i, isFinal: i == count - 1);
        expect(clear.length, expectedClearLengths[i]);
        out.add(clear);
      }
      expect(out.takeBytes(), content);
    }

    test('空文件：1 个空块，密文只有标签', () => roundTrip(0, [0]));
    test('不足一块', () => roundTrip(1000, [1000]));
    test('正好一块', () => roundTrip(_mib, [_mib]));
    test('多块且末块不满', () => roundTrip(2 * _mib + 12345, [_mib, _mib, 12345]));

    test('格式符合约定：nonce、附加数据、密文‖标签', () async {
      final content = _pattern(_mib + 10);
      final file = await source(content);
      final keys = FileKeys(
        key: Uint8List.fromList(List.generate(32, (i) => i)),
        noncePrefix: Uint8List.fromList(List.generate(16, (i) => 0xa0 + i)),
      );
      final sealed = await FileCipher.sealChunk(file, keys, 1);

      final nonce = <int>[...keys.noncePrefix, 0, 0, 0, 0, 0, 0, 0, 1];
      final aad = <int>[0, 0, 0, 0, 0, 0, 0, 1, 0x01];
      final box = await Xchacha20.poly1305Aead().encrypt(
        content.sublist(_mib),
        secretKey: SecretKey(keys.key),
        nonce: nonce,
        aad: aad,
      );
      expect(sealed, [...box.cipherText, ...box.mac.bytes]);
    });

    test('index 越界抛 RangeError', () async {
      final file = await source(_pattern(100));
      final keys = FileKeys.random();
      await expectLater(FileCipher.sealChunk(file, keys, 1), throwsRangeError);
      await expectLater(FileCipher.sealChunk(file, keys, -1), throwsRangeError);
      final empty = await source(Uint8List(0), 'empty.bin');
      expect(await FileCipher.sealChunk(empty, keys, 0), hasLength(16));
      await expectLater(FileCipher.sealChunk(empty, keys, 1), throwsRangeError);
    });

    test('改动任一字节（密文或标签）认证失败', () async {
      final file = await source(_pattern(5000));
      final keys = FileKeys.random();
      final sealed = await FileCipher.sealChunk(file, keys, 0);
      for (final position in [0, 2500, sealed.length - 1]) {
        final tampered = Uint8List.fromList(sealed);
        tampered[position] ^= 0x01;
        await expectLater(
          FileCipher.openChunk(tampered, keys, 0, isFinal: true),
          throwsA(isA<FileCipherException>()),
        );
      }
      // 原样仍可解开
      expect(await FileCipher.openChunk(sealed, keys, 0, isFinal: true), hasLength(5000));
    });

    test('调换两块认证失败', () async {
      final file = await source(_pattern(3 * _mib));
      final keys = FileKeys.random();
      final sealed0 = await FileCipher.sealChunk(file, keys, 0);
      final sealed1 = await FileCipher.sealChunk(file, keys, 1);
      await expectLater(
        FileCipher.openChunk(sealed1, keys, 0, isFinal: false),
        throwsA(isA<FileCipherException>()),
      );
      await expectLater(
        FileCipher.openChunk(sealed0, keys, 1, isFinal: false),
        throwsA(isA<FileCipherException>()),
      );
    });

    test('末块标志不符认证失败（截断）', () async {
      final file = await source(_pattern(_mib + 100));
      final keys = FileKeys.random();
      final sealed0 = await FileCipher.sealChunk(file, keys, 0);
      final sealed1 = await FileCipher.sealChunk(file, keys, 1);
      await expectLater(
        FileCipher.openChunk(sealed0, keys, 0, isFinal: true),
        throwsA(isA<FileCipherException>()),
      );
      await expectLater(
        FileCipher.openChunk(sealed1, keys, 1, isFinal: false),
        throwsA(isA<FileCipherException>()),
      );
    });

    test('别的密钥或过短的密文块认证失败', () async {
      final file = await source(_pattern(100));
      final keys = FileKeys.random();
      final sealed = await FileCipher.sealChunk(file, keys, 0);
      await expectLater(
        FileCipher.openChunk(sealed, FileKeys.random(), 0, isFinal: true),
        throwsA(isA<FileCipherException>()),
      );
      await expectLater(
        FileCipher.openChunk(Uint8List(15), keys, 0, isFinal: true),
        throwsA(isA<FileCipherException>()),
      );
    });
  });

  group('FileReceiver', () {
    File partOf(File target) => File('${target.path}.part');

    Future<void> receiveWhole(int size) async {
      final content = _pattern(size);
      final file = await source(content);
      final keys = FileKeys.random();
      final chunks = await sealAll(file, keys);
      final target = File('${dir.path}/out.bin');

      final receiver = await FileReceiver.open(
        target: target,
        keys: keys,
        size: size,
        hash: await FileCipher.hashFile(file),
      );
      expect(receiver.nextIndex, 0);
      expect(receiver.chunkCount, chunks.length);
      for (var i = 0; i < chunks.length; i++) {
        await receiver.addChunk(i, chunks[i]);
        expect(receiver.nextIndex, i + 1);
      }
      final result = await receiver.finish();
      expect(result.path, target.path);
      expect(await target.readAsBytes(), content);
      expect(await partOf(target).exists(), isFalse);
    }

    test('空文件', () => receiveWhole(0));
    test('不足一块', () => receiveWhole(777));
    test('正好一块', () => receiveWhole(_mib));
    test('多块且末块不满', () => receiveWhole(2 * _mib + 999));

    test('序号不等于 nextIndex 抛 StateError；没写完 finish 抛 StateError', () async {
      final file = await source(_pattern(2 * _mib + 5));
      final keys = FileKeys.random();
      final chunks = await sealAll(file, keys);
      final target = File('${dir.path}/out.bin');
      final receiver = await FileReceiver.open(
        target: target,
        keys: keys,
        size: await file.length(),
        hash: await FileCipher.hashFile(file),
      );
      await expectLater(receiver.addChunk(1, chunks[1]), throwsStateError);
      expect(receiver.nextIndex, 0);
      await receiver.addChunk(0, chunks[0]);
      await expectLater(receiver.addChunk(0, chunks[0]), throwsStateError);
      await expectLater(receiver.finish(), throwsStateError);
      expect(receiver.nextIndex, 1);
      // 报错后仍可继续
      await receiver.addChunk(1, chunks[1]);
      await receiver.addChunk(2, chunks[2]);
      await expectLater(receiver.addChunk(3, chunks[2]), throwsStateError);
      await receiver.finish();
      expect(await target.readAsBytes(), await file.readAsBytes());
    });

    test('认证失败不写入、nextIndex 不变，重新给对的块可以继续', () async {
      final file = await source(_pattern(2 * _mib + 5));
      final keys = FileKeys.random();
      final chunks = await sealAll(file, keys);
      final target = File('${dir.path}/out.bin');
      final receiver = await FileReceiver.open(
        target: target,
        keys: keys,
        size: await file.length(),
        hash: await FileCipher.hashFile(file),
      );
      await receiver.addChunk(0, chunks[0]);

      final tampered = Uint8List.fromList(chunks[1])..[10] ^= 0xff;
      await expectLater(receiver.addChunk(1, tampered), throwsA(isA<FileCipherException>()));
      // 调换：把第 2 块当第 1 块
      await expectLater(receiver.addChunk(1, chunks[2]), throwsA(isA<FileCipherException>()));
      expect(receiver.nextIndex, 1);
      expect(await partOf(target).length(), _mib);

      await receiver.addChunk(1, chunks[1]);
      await receiver.addChunk(2, chunks[2]);
      await receiver.finish();
      expect(await target.readAsBytes(), await file.readAsBytes());
    });

    test('截断：把长文件的非末块当成短文件的末块会失败', () async {
      final file = await source(_pattern(2 * _mib + 5));
      final keys = FileKeys.random();
      final chunks = await sealAll(file, keys);
      final target = File('${dir.path}/out.bin');
      // 攻击者声称文件只有 1 块
      final receiver = await FileReceiver.open(
        target: target,
        keys: keys,
        size: _mib,
        hash: await FileCipher.hashFile(file),
      );
      expect(receiver.chunkCount, 1);
      await expectLater(receiver.addChunk(0, chunks[0]), throwsA(isA<FileCipherException>()));
      expect(receiver.nextIndex, 0);
      await receiver.abort();
      expect(await partOf(target).exists(), isFalse);
      expect(await target.exists(), isFalse);
    });

    test('续传：写一部分后重新 open，nextIndex 正确，最后内容一致', () async {
      final content = _pattern(2 * _mib + 4096);
      final file = await source(content);
      final keys = FileKeys.random();
      final chunks = await sealAll(file, keys);
      final hash = await FileCipher.hashFile(file);
      final target = File('${dir.path}/out.bin');

      final first = await FileReceiver.open(
        target: target,
        keys: keys,
        size: content.length,
        hash: hash,
      );
      await first.addChunk(0, chunks[0]);
      await first.addChunk(1, chunks[1]);
      // 模拟进程中断：不 finish 也不 abort，临时文件留在原地
      expect(await partOf(target).length(), 2 * _mib);

      final second = await FileReceiver.open(
        target: target,
        keys: keys,
        size: content.length,
        hash: hash,
      );
      expect(second.nextIndex, 2);
      expect(second.chunkCount, 3);
      await expectLater(second.addChunk(0, chunks[0]), throwsStateError);
      await second.addChunk(2, chunks[2]);
      await second.finish();
      expect(await target.readAsBytes(), content);
      expect(await partOf(target).exists(), isFalse);
    });

    test('临时文件长度不是整块或不小于 size 时从头开始', () async {
      final content = _pattern(_mib + 100);
      final file = await source(content);
      final keys = FileKeys.random();
      final chunks = await sealAll(file, keys);
      final hash = await FileCipher.hashFile(file);
      final target = File('${dir.path}/out.bin');

      for (final staleLength in [123, 2 * _mib]) {
        await partOf(target).writeAsBytes(Uint8List(staleLength), flush: true);
        final receiver = await FileReceiver.open(
          target: target,
          keys: keys,
          size: content.length,
          hash: hash,
        );
        expect(receiver.nextIndex, 0, reason: '残留长度 $staleLength');
        expect(await partOf(target).length(), 0);
        await receiver.addChunk(0, chunks[0]);
        await receiver.addChunk(1, chunks[1]);
        await receiver.finish();
        expect(await target.readAsBytes(), content);
        await target.delete();
      }
    });

    test('哈希不符时 finish 失败并删除临时文件', () async {
      final file = await source(_pattern(_mib + 100));
      final keys = FileKeys.random();
      final chunks = await sealAll(file, keys);
      final wrongHash = await FileCipher.hashFile(file);
      wrongHash[0] ^= 0x01;
      final target = File('${dir.path}/out.bin');
      final receiver = await FileReceiver.open(
        target: target,
        keys: keys,
        size: await file.length(),
        hash: wrongHash,
      );
      await receiver.addChunk(0, chunks[0]);
      await receiver.addChunk(1, chunks[1]);
      await expectLater(receiver.finish(), throwsA(isA<FileCipherException>()));
      expect(await partOf(target).exists(), isFalse);
      expect(await target.exists(), isFalse);
    });

    test('abort 关闭并删除临时文件', () async {
      final file = await source(_pattern(_mib + 100));
      final keys = FileKeys.random();
      final chunks = await sealAll(file, keys);
      final target = File('${dir.path}/out.bin');
      final receiver = await FileReceiver.open(
        target: target,
        keys: keys,
        size: await file.length(),
        hash: await FileCipher.hashFile(file),
      );
      await receiver.addChunk(0, chunks[0]);
      expect(await partOf(target).exists(), isTrue);
      await receiver.abort();
      expect(await partOf(target).exists(), isFalse);
      expect(await target.exists(), isFalse);
      await expectLater(receiver.addChunk(1, chunks[1]), throwsStateError);
    });

    test('size 或 hash 不合格抛 ArgumentError', () async {
      final target = File('${dir.path}/out.bin');
      final keys = FileKeys.random();
      await expectLater(
        FileReceiver.open(target: target, keys: keys, size: -1, hash: Uint8List(32)),
        throwsArgumentError,
      );
      await expectLater(
        FileReceiver.open(
          target: target,
          keys: keys,
          size: FileCipher.maxFileBytes + 1,
          hash: Uint8List(32),
        ),
        throwsArgumentError,
      );
      await expectLater(
        FileReceiver.open(target: target, keys: keys, size: 10, hash: Uint8List(31)),
        throwsArgumentError,
      );
      expect(await partOf(target).exists(), isFalse);
    });
  });
}
