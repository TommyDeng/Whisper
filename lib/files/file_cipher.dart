import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// 文件中转用的分块加密，约定见 docs/file-relay.md 的“分块与加密”。

/// 一个文件的密钥材料：每个文件随机生成，只通过端到端加密的消息传给对方。
class FileKeys {
  FileKeys({required this.key, required this.noncePrefix}) {
    if (key.length != keyLength) {
      throw ArgumentError.value(key.length, 'key', '密钥必须是 $keyLength 字节');
    }
    if (noncePrefix.length != noncePrefixLength) {
      throw ArgumentError.value(
        noncePrefix.length,
        'noncePrefix',
        'noncePrefix 必须是 $noncePrefixLength 字节',
      );
    }
  }

  factory FileKeys.random() {
    final random = Random.secure();
    Uint8List bytes(int length) =>
        Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
    return FileKeys(key: bytes(keyLength), noncePrefix: bytes(noncePrefixLength));
  }

  static const int keyLength = 32;
  static const int noncePrefixLength = 16;

  final Uint8List key; // 32 字节
  final Uint8List noncePrefix; // 16 字节
}

class FileCipherException implements Exception {
  FileCipherException(this.message);

  final String message;

  @override
  String toString() => 'FileCipherException: $message';
}

class FileCipher {
  FileCipher._();

  static const int chunkSize = 1024 * 1024;
  static const int tagLength = 16;
  static const int maxFileBytes = 100 * 1024 * 1024;
  static const int hashLength = 32;

  static final _aead = Xchacha20.poly1305Aead();

  /// 文件大小对应的块数；size 为负抛 ArgumentError。空文件是 1 个空块。
  static int chunkCount(int size) {
    if (size < 0) {
      throw ArgumentError.value(size, 'size', '文件大小不能为负');
    }
    if (size == 0) return 1;
    return (size + chunkSize - 1) ~/ chunkSize;
  }

  /// 流式计算文件明文的 BLAKE2b-256。
  static Future<Uint8List> hashFile(File file) async {
    final sink = Blake2b(hashLengthInBytes: hashLength).newHashSink();
    await for (final part in file.openRead()) {
      sink.add(part);
    }
    sink.close();
    final hash = await sink.hash();
    return Uint8List.fromList(hash.bytes);
  }

  /// 从文件里读出第 index 块并加密，返回密文块。index 越界抛 RangeError。
  static Future<Uint8List> sealChunk(File file, FileKeys keys, int index) async {
    final size = await file.length();
    final count = chunkCount(size);
    RangeError.checkValueInInterval(index, 0, count - 1, 'index');
    final offset = index * chunkSize;
    final length = min(chunkSize, size - offset);

    final Uint8List clear;
    final raf = await file.open();
    try {
      await raf.setPosition(offset);
      clear = await _readFully(raf, length);
    } finally {
      await raf.close();
    }

    final isFinal = index == count - 1;
    final box = await _aead.encrypt(
      clear,
      secretKey: SecretKey(keys.key),
      nonce: _nonce(keys, index),
      aad: _aad(index, isFinal),
    );
    final sealed = Uint8List(box.cipherText.length + tagLength);
    sealed.setRange(0, box.cipherText.length, box.cipherText);
    sealed.setRange(box.cipherText.length, sealed.length, box.mac.bytes);
    return sealed;
  }

  /// 解密一个密文块。认证失败（内容、序号或末块标志不对）抛 FileCipherException。
  static Future<Uint8List> openChunk(
    Uint8List sealed,
    FileKeys keys,
    int index, {
    required bool isFinal,
  }) async {
    if (index < 0) {
      throw RangeError.value(index, 'index', '块序号不能为负');
    }
    if (sealed.length < tagLength) {
      throw FileCipherException('密文块太短');
    }
    final split = sealed.length - tagLength;
    final box = SecretBox(
      Uint8List.sublistView(sealed, 0, split),
      nonce: _nonce(keys, index),
      mac: Mac(Uint8List.sublistView(sealed, split)),
    );
    try {
      final clear = await _aead.decrypt(
        box,
        secretKey: SecretKey(keys.key),
        aad: _aad(index, isFinal),
      );
      return clear is Uint8List ? clear : Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw FileCipherException('第 $index 块认证失败');
    }
  }

  /// nonce（24 字节）= noncePrefix（16 字节）‖ 块序号（8 字节大端）。
  static Uint8List _nonce(FileKeys keys, int index) {
    final nonce = Uint8List(24)..setRange(0, 16, keys.noncePrefix);
    ByteData.sublistView(nonce).setUint64(16, index);
    return nonce;
  }

  /// 附加数据（9 字节）= 块序号（8 字节大端）‖ 末块标志。
  static Uint8List _aad(int index, bool isFinal) {
    final aad = Uint8List(9);
    ByteData.sublistView(aad).setUint64(0, index);
    aad[8] = isFinal ? 0x01 : 0x00;
    return aad;
  }

  static Future<Uint8List> _readFully(RandomAccessFile raf, int length) async {
    final buffer = Uint8List(length);
    var read = 0;
    while (read < length) {
      final n = await raf.readInto(buffer, read, length);
      if (n <= 0) {
        throw FileSystemException('文件比预期的短', raf.path);
      }
      read += n;
    }
    return buffer;
  }
}

/// 接收端：按顺序把密文块解密后写进临时文件，全部写完并校验通过后改名为目标文件。
class FileReceiver {
  FileReceiver._(
    this.target,
    this._keys,
    this._size,
    this._hash,
    this._part,
    this._raf,
    this._nextIndex,
  ) : chunkCount = FileCipher.chunkCount(_size);

  /// 临时文件是 `<target>.part`。它已存在时接着写（断点续传）：
  /// 已有长度必须是 chunkSize 的整数倍且小于 size，否则删掉从头开始。
  static Future<FileReceiver> open({
    required File target,
    required FileKeys keys,
    required int size,
    required Uint8List hash,
  }) async {
    if (size < 0 || size > FileCipher.maxFileBytes) {
      throw ArgumentError.value(size, 'size', '文件大小必须在 0 到 ${FileCipher.maxFileBytes} 之间');
    }
    if (hash.length != FileCipher.hashLength) {
      throw ArgumentError.value(hash.length, 'hash', '哈希必须是 ${FileCipher.hashLength} 字节');
    }
    final part = File('${target.path}.part');
    var nextIndex = 0;
    if (await part.exists()) {
      final existing = await part.length();
      if (existing % FileCipher.chunkSize == 0 && existing < size) {
        nextIndex = existing ~/ FileCipher.chunkSize;
      } else {
        await part.delete();
      }
    }
    final raf = await part.open(mode: FileMode.append);
    return FileReceiver._(target, keys, size, Uint8List.fromList(hash), part, raf, nextIndex);
  }

  final File target;
  final FileKeys _keys;
  final int _size;
  final Uint8List _hash;
  final File _part;
  final RandomAccessFile _raf;
  int _nextIndex;
  bool _busy = false;
  bool _closed = false;

  /// 下一个要写的块序号（续传时不是 0）。
  int get nextIndex => _nextIndex;

  final int chunkCount;

  /// 解密并追加一块。index 必须等于 nextIndex，否则抛 StateError。
  /// 认证失败抛 FileCipherException，且不写入、nextIndex 不变（调用方可以重新下载这一块）。
  Future<void> addChunk(int index, Uint8List sealed) => _exclusive(() async {
        if (_nextIndex >= chunkCount) {
          throw StateError('所有块都已写完');
        }
        if (index != _nextIndex) {
          throw StateError('块序号应为 $_nextIndex，收到 $index');
        }
        final isFinal = index == chunkCount - 1;
        final clear = await FileCipher.openChunk(sealed, _keys, index, isFinal: isFinal);
        final offset = index * FileCipher.chunkSize;
        final expected = isFinal ? _size - offset : FileCipher.chunkSize;
        if (clear.length != expected) {
          throw FileCipherException('第 $index 块长度不对：应为 $expected，实际 ${clear.length}');
        }
        try {
          await _raf.writeFrom(clear);
          await _raf.flush();
        } catch (_) {
          // 写到一半失败：退回到块边界，保证临时文件仍可续传。
          try {
            await _raf.truncate(offset);
          } catch (_) {}
          rethrow;
        }
        _nextIndex = index + 1;
      });

  /// 所有块写完后调用：校验总长度和整文件哈希，通过则把临时文件改名为 target 并返回它。
  /// 不通过则删除临时文件并抛 FileCipherException。块没写完时调用抛 StateError。
  Future<File> finish() => _exclusive(() async {
        if (_nextIndex < chunkCount) {
          throw StateError('还有块没写完：$_nextIndex / $chunkCount');
        }
        _closed = true;
        await _raf.close();
        final length = await _part.length();
        var ok = length == _size;
        if (ok) {
          final actual = await FileCipher.hashFile(_part);
          var diff = 0;
          for (var i = 0; i < _hash.length; i++) {
            diff |= actual[i] ^ _hash[i];
          }
          ok = diff == 0;
        }
        if (!ok) {
          await _deletePart();
          throw FileCipherException('文件校验失败：长度或哈希不符');
        }
        return _part.rename(target.path);
      });

  /// 放弃：关闭并删除临时文件。
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    await _raf.close();
    await _deletePart();
  }

  Future<void> _deletePart() async {
    if (await _part.exists()) {
      await _part.delete();
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (_closed) {
      throw StateError('接收已结束');
    }
    if (_busy) {
      throw StateError('上一个操作还没完成');
    }
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }
}
