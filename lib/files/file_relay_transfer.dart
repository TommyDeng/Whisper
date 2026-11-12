import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'file_cipher.dart';
import 'file_offer.dart';
import 'file_relay_api.dart';

// 经中继传一个文件：发送端逐块加密上传，接收端逐块下载解密、可断点续传。
// 行为约定见 docs/file-relay.md 的“传输”。

/// 传输被 [CancelToken.cancel] 取消。
class TransferCancelled implements Exception {
  const TransferCancelled();

  @override
  String toString() => 'TransferCancelled';
}

/// 传输失败。[code] 是：
/// `too-large`（超过 100 MiB）、`network`（重试用尽）、`not-found`（中继上没有，过期或已删）、
/// `corrupt`（认证或校验失败）、`changed`（上传途中源文件变了）、`rejected`（中继拒绝）。
class FileTransferException implements Exception {
  const FileTransferException(this.code);

  final String code;

  @override
  String toString() => 'FileTransferException($code)';
}

class CancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// [done] 和 [total] 都是明文字节数。
typedef TransferProgress = void Function(int done, int total);

class FileRelayTransfer {
  FileRelayTransfer(
    this.api, {
    this.retries = 3,
    this.retryDelay = const Duration(seconds: 1),
  });

  final FileRelayApi api;

  /// 单块遇到网络错误时最多重试几次。
  final int retries;

  /// 第 n 次重试前等 n × [retryDelay]。
  final Duration retryDelay;

  /// 加密上传 [file]，返回发给对方的 [FileOffer]。失败或取消时尽力删除已上传的块。
  Future<FileOffer> upload(
    File file, {
    CancelToken? cancel,
    TransferProgress? onProgress,
  }) async {
    final size = await file.length();
    if (size > FileCipher.maxFileBytes) {
      throw const FileTransferException('too-large');
    }
    final hash = await FileCipher.hashFile(file);
    final keys = FileKeys.random();
    final fileId = FileOffer.newFileId();
    final count = FileCipher.chunkCount(size);
    var attempted = false;
    try {
      onProgress?.call(0, size);
      for (var index = 0; index < count; index++) {
        _check(cancel);
        final Uint8List sealed;
        try {
          sealed = await FileCipher.sealChunk(file, keys, index);
        } on RangeError {
          throw const FileTransferException('changed'); // 文件变短了
        }
        attempted = true;
        await _withRetry(() => api.putChunk(fileId, index, sealed), cancel);
        onProgress?.call(
          index == count - 1 ? size : (index + 1) * FileCipher.chunkSize,
          size,
        );
      }
      _check(cancel);
      if (await file.length() != size) {
        throw const FileTransferException('changed');
      }
      return FileOffer(
        fileId: fileId,
        name: _offerName(file),
        size: size,
        keys: keys,
        hash: hash,
      );
    } catch (error) {
      if (attempted) await discard(fileId);
      if (error is FileSystemException) {
        throw const FileTransferException('changed');
      }
      rethrow;
    }
  }

  /// 下载 [offer] 到 [target]（临时文件是 `<target>.part`，已存在时续传）。
  /// 成功后返回目标文件，并尽力删除中继上的块。
  Future<File> download(
    FileOffer offer,
    File target, {
    CancelToken? cancel,
    TransferProgress? onProgress,
  }) async {
    final receiver = await FileReceiver.open(
      target: target,
      keys: offer.keys,
      size: offer.size,
      hash: offer.hash,
    );
    int done(int nextIndex) => nextIndex >= receiver.chunkCount
        ? offer.size
        : nextIndex * FileCipher.chunkSize;

    try {
      onProgress?.call(done(receiver.nextIndex), offer.size);
      while (receiver.nextIndex < receiver.chunkCount) {
        final index = receiver.nextIndex;
        _check(cancel);
        var sealed = await _withRetry(() => api.getChunk(offer.fileId, index), cancel);
        try {
          await receiver.addChunk(index, sealed);
        } on FileCipherException {
          // 可能是传输中损坏：重新下载这一块一次
          _check(cancel);
          sealed = await _withRetry(() => api.getChunk(offer.fileId, index), cancel);
          await receiver.addChunk(index, sealed);
        }
        onProgress?.call(done(receiver.nextIndex), offer.size);
      }
      _check(cancel);
    } on FileCipherException {
      await receiver.abort();
      throw const FileTransferException('corrupt');
    } on FileTransferException catch (error) {
      // 中继上已经没有了，临时文件留着也续不上；其它情况可以续传
      if (error.code == 'not-found') {
        await receiver.abort();
      } else {
        await receiver.close();
      }
      rethrow;
    } catch (_) {
      // 取消，或写盘之类的本地错误：留着临时文件
      await receiver.close();
      rethrow;
    }

    final File saved;
    try {
      saved = await receiver.finish();
    } on FileCipherException {
      throw const FileTransferException('corrupt');
    }
    await discard(offer.fileId);
    return saved;
  }

  /// 尽力删除中继上的文件；失败不报错（7 天后中继自己会清）。
  Future<void> discard(String fileId) async {
    try {
      await api.deleteFile(fileId);
    } catch (_) {}
  }

  static String _offerName(File file) {
    var name = p.basename(file.path);
    if (name.length > FileOffer.maxNameLength) {
      name = name.substring(name.length - FileOffer.maxNameLength); // 保住扩展名
    }
    return name.isEmpty ? 'file' : name;
  }

  static void _check(CancelToken? cancel) {
    if (cancel != null && cancel.isCancelled) throw const TransferCancelled();
  }

  /// 调一次中继接口；暂时性的错误重试，其余换成 [FileTransferException]。
  Future<T> _withRetry<T>(Future<T> Function() call, CancelToken? cancel) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await call();
      } on FileRelayException catch (error) {
        if (error.status == 404) throw const FileTransferException('not-found');
        if (!error.isTransient) throw const FileTransferException('rejected');
        if (attempt >= retries) throw const FileTransferException('network');
      }
      await Future<void>.delayed(retryDelay * (attempt + 1));
      _check(cancel);
    }
  }
}
