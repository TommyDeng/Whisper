import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/files/file_cipher.dart';
import 'package:whisper/files/file_offer.dart';
import 'package:whisper/files/file_relay_api.dart';
import 'package:whisper/files/file_relay_transfer.dart';

import 'fake_file_relay.dart';

const _mib = FileCipher.chunkSize;
const _auth = FileRelayAuth(sessionId: 'AAAAAAAAAAAAAAAAAAAAAA', peer: 'a');

void main() {
  late Directory dir;
  late FakeFileRelay relay;
  late FileRelayTransfer transfer;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('whisper_file_transfer_');
    relay = FakeFileRelay();
    transfer = FileRelayTransfer(relay, retryDelay: Duration.zero);
  });

  tearDown(() => dir.delete(recursive: true));

  Future<File> source(int size, [String name = 'source.bin']) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(pattern(size), flush: true);
    return file;
  }

  File target([String name = 'out.bin']) => File('${dir.path}/$name');
  File partOf(File file) => File('${file.path}.part');

  Matcher failure(String code) =>
      isA<FileTransferException>().having((e) => e.code, 'code', code);

  group('往返', () {
    for (final size in [0, 777, _mib, 2 * _mib + 999]) {
      test('$size 字节', () async {
        final file = await source(size, '报告.pdf');
        final up = <int>[];
        final offer = await transfer.upload(file, auth: _auth, onProgress: (done, total) {
          expect(total, size);
          up.add(done);
        });
        expect(offer.name, '报告.pdf');
        expect(offer.size, size);
        expect(offer.hash, await FileCipher.hashFile(file));
        expect(relay.files[offer.fileId]!.keys.toList(), [
          for (var i = 0; i < FileCipher.chunkCount(size); i++) i,
        ]);
        expect(up.first, 0);
        expect(up.last, size);
        expect(relay.deleted, isEmpty);

        // 经过消息编码再解出来的 offer 一样能下载
        final received = FileOffer.decode(offer.encode());
        final down = <int>[];
        final saved = await transfer.download(received, target(), auth: _auth, onProgress: (done, _) => down.add(done));
        expect(saved.path, target().path);
        expect(await saved.readAsBytes(), await file.readAsBytes());
        expect(await partOf(target()).exists(), isFalse);
        expect(down.first, 0);
        expect(down.last, size);
        expect(down, orderedEquals([...down]..sort()));
        // 下载完成后删掉中继上的块
        expect(relay.deleted, [offer.fileId]);
      });
    }
  });

  group('上传', () {
    test('中继上只有密文', () async {
      final file = await source(4096);
      final offer = await transfer.upload(file, auth: _auth);
      final sealed = relay.files[offer.fileId]![0]!;
      expect(sealed.length, 4096 + FileCipher.tagLength);
      expect(sealed.sublist(0, 4096), isNot(await file.readAsBytes()));
    });

    test('超过 100 MiB 拒绝，不碰中继', () async {
      final file = File('${dir.path}/big.bin');
      final raf = await file.open(mode: FileMode.write);
      await raf.truncate(FileCipher.maxFileBytes + 1);
      await raf.close();
      await expectLater(transfer.upload(file, auth: _auth), throwsA(failure('too-large')));
      expect(relay.calls, isEmpty);
    });

    test('暂时性错误重试后成功', () async {
      var failures = 0;
      relay.before = (op, index) async {
        if (op == 'put' && index == 1 && failures < 2) {
          failures++;
          throw FileRelayException(failures == 1 ? 0 : 503, 'x');
        }
      };
      final file = await source(2 * _mib + 5);
      final offer = await transfer.upload(file, auth: _auth);
      expect(relay.count('put 1'), 3);
      expect(relay.files[offer.fileId], hasLength(3));
    });

    test('重试用尽：抛 network 并删除已上传的块', () async {
      relay.before = (op, index) async {
        if (op == 'put' && index == 1) throw const FileRelayException(0, 'network');
      };
      final file = await source(2 * _mib + 5);
      await expectLater(transfer.upload(file, auth: _auth), throwsA(failure('network')));
      expect(relay.count('put 1'), 4); // 1 次 + 3 次重试
      expect(relay.deleted, hasLength(1));
      expect(relay.files, isEmpty);
    });

    test('中继拒绝：不重试，抛 rejected', () async {
      relay.before = (op, index) async {
        if (op == 'put') throw const FileRelayException(413, 'chunk-too-large');
      };
      await expectLater(transfer.upload(await source(10), auth: _auth), throwsA(failure('rejected')));
      expect(relay.count('put 0'), 1);
    });

    test('未鉴权、禁止访问或配额超额：不重试，抛 rejected，并带上凭据', () async {
      for (final error in [
        const FileRelayException(401, 'unauthorized'),
        const FileRelayException(403, 'forbidden'),
        const FileRelayException(413, 'quota-exceeded'),
      ]) {
        relay = FakeFileRelay();
        transfer = FileRelayTransfer(relay, retryDelay: Duration.zero);
        relay.before = (op, index) async {
          if (op == 'put') throw error;
        };
        await expectLater(transfer.upload(await source(10), auth: _auth), throwsA(failure('rejected')));
        expect(relay.count('put 0'), 1);
        expect(relay.lastAuth, same(_auth));
      }
    });

    test('取消：抛 TransferCancelled 并删除已上传的块', () async {
      final cancel = CancelToken();
      relay.before = (op, index) async {
        if (op == 'put' && index == 0) cancel.cancel();
      };
      final file = await source(2 * _mib + 5);
      await expectLater(
        transfer.upload(file, auth: _auth, cancel: cancel),
        throwsA(isA<TransferCancelled>()),
      );
      expect(relay.count('put 1'), 0);
      expect(relay.deleted, hasLength(1));
      expect(relay.files, isEmpty);
    });

    test('删除失败不影响原来的错误', () async {
      relay.before = (op, index) async {
        if (op == 'put' && index == 1) throw const FileRelayException(400, 'bad');
        if (op == 'delete') throw const FileRelayException(0, 'network');
      };
      await expectLater(transfer.upload(await source(_mib + 1), auth: _auth), throwsA(failure('rejected')));
    });

    test('上传途中文件变了：抛 changed', () async {
      final file = await source(_mib + 100);
      relay.before = (op, index) async {
        if (op == 'put' && index == 1) {
          await file.writeAsBytes(Uint8List(10), mode: FileMode.append, flush: true);
        }
      };
      await expectLater(transfer.upload(file, auth: _auth), throwsA(failure('changed')));
      expect(relay.files, isEmpty);

      final shrinking = await source(2 * _mib, 'shrinking.bin');
      relay.before = (op, index) async {
        if (op == 'put' && index == 0) await shrinking.writeAsBytes(Uint8List(10), flush: true);
      };
      await expectLater(transfer.upload(shrinking, auth: _auth), throwsA(failure('changed')));

      await expectLater(
        transfer.upload(File('${dir.path}/missing.bin'), auth: _auth),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('下载', () {
    late File file;
    late FileOffer offer;
    const size = 3 * _mib + 321;

    setUp(() async {
      file = await source(size);
      offer = await transfer.upload(file, auth: _auth);
      relay.calls.clear();
    });

    test('取消后保留临时文件，再下载时续传', () async {
      final cancel = CancelToken();
      relay.before = (op, index) async {
        if (op == 'get' && index == 1) cancel.cancel();
      };
      await expectLater(
        transfer.download(offer, target(), auth: _auth, cancel: cancel),
        throwsA(isA<TransferCancelled>()),
      );
      expect(await partOf(target()).length(), 2 * _mib);
      expect(await target().exists(), isFalse);
      expect(relay.deleted, isEmpty);

      relay.before = null;
      relay.calls.clear();
      final progress = <int>[];
      final saved = await transfer.download(offer, target(), auth: _auth, onProgress: (done, _) => progress.add(done));
      expect(relay.calls, ['get 2', 'get 3', 'delete']);
      expect(progress.first, 2 * _mib);
      expect(progress.last, size);
      expect(await saved.readAsBytes(), await file.readAsBytes());
    });

    test('网络错误重试用尽：抛 network，保留临时文件，可续传', () async {
      relay.before = (op, index) async {
        if (op == 'get' && index == 2) throw const FileRelayException(0, 'network');
      };
      await expectLater(transfer.download(offer, target(), auth: _auth), throwsA(failure('network')));
      expect(relay.count('get 2'), 4);
      expect(await partOf(target()).length(), 2 * _mib);

      relay.before = null;
      relay.calls.clear();
      await transfer.download(offer, target(), auth: _auth);
      expect(relay.calls, ['get 2', 'get 3', 'delete']);
      expect(await target().readAsBytes(), await file.readAsBytes());
    });

    test('块全部写完但没来得及校验：再下载时不再请求任何块', () async {
      final cancel = CancelToken();
      relay.before = (op, index) async {
        if (op == 'get' && index == 3) cancel.cancel(); // 最后一块写完后才发现取消
      };
      await expectLater(
        transfer.download(offer, target(), auth: _auth, cancel: cancel),
        throwsA(isA<TransferCancelled>()),
      );
      expect(await partOf(target()).length(), size);

      relay.before = null;
      relay.calls.clear();
      final saved = await transfer.download(offer, target(), auth: _auth);
      expect(relay.calls, ['delete']);
      expect(await saved.readAsBytes(), await file.readAsBytes());
    });

    test('中继上已经没有：抛 not-found，删除临时文件', () async {
      relay.files[offer.fileId]!.remove(2);
      await expectLater(transfer.download(offer, target(), auth: _auth), throwsA(failure('not-found')));
      expect(relay.count('get 2'), 1);
      expect(await partOf(target()).exists(), isFalse);
      expect(await target().exists(), isFalse);
    });

    test('某块损坏一次：重新下载这一块后成功', () async {
      var tampered = 0;
      relay.tamper = (index, sealed) {
        if (index == 1 && tampered == 0) {
          tampered++;
          sealed[100] ^= 0xff;
        }
        return sealed;
      };
      final saved = await transfer.download(offer, target(), auth: _auth);
      expect(relay.count('get 1'), 2);
      expect(await saved.readAsBytes(), await file.readAsBytes());
    });

    test('某块一直损坏：抛 corrupt，删除临时文件，不删中继上的文件', () async {
      relay.tamper = (index, sealed) {
        if (index == 1) sealed[100] ^= 0xff;
        return sealed;
      };
      await expectLater(transfer.download(offer, target(), auth: _auth), throwsA(failure('corrupt')));
      expect(relay.count('get 1'), 2);
      expect(await partOf(target()).exists(), isFalse);
      expect(await target().exists(), isFalse);
      expect(relay.deleted, isEmpty);
    });

    test('整文件哈希不符：抛 corrupt，不留下任何文件', () async {
      final wrong = Uint8List.fromList(offer.hash)..[0] ^= 1;
      final bad = FileOffer(
        fileId: offer.fileId,
        name: offer.name,
        size: offer.size,
        keys: offer.keys,
        hash: wrong,
      );
      await expectLater(transfer.download(bad, target(), auth: _auth), throwsA(failure('corrupt')));
      expect(await partOf(target()).exists(), isFalse);
      expect(await target().exists(), isFalse);
      expect(relay.deleted, isEmpty);
    });

    test('大小与实际不符（截断或加长）：抛 corrupt', () async {
      for (final claimed in [2 * _mib, size + _mib]) {
        final bad = FileOffer(
          fileId: offer.fileId,
          name: offer.name,
          size: claimed,
          keys: offer.keys,
          hash: offer.hash,
        );
        await expectLater(
          transfer.download(bad, target(), auth: _auth),
          throwsA(failure('corrupt')),
          reason: '声称 $claimed',
        );
        expect(await target().exists(), isFalse);
      }
    });

    test('完成后删除中继文件失败不影响结果', () async {
      relay.before = (op, index) async {
        if (op == 'delete') throw const FileRelayException(500, '');
      };
      final saved = await transfer.download(offer, target(), auth: _auth);
      expect(await saved.readAsBytes(), await file.readAsBytes());
    });
  });
}
