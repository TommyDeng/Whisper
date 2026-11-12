import 'dart:typed_data';

import 'package:whisper/files/file_relay_api.dart';

/// 内存里的假文件中继：记录调用，可以按次序注入错误或篡改下载内容。
class FakeFileRelay implements FileRelayApi {
  /// fileId → 块序号 → 密文块。
  final Map<String, Map<int, Uint8List>> files = {};

  final List<String> calls = []; // 例如 `put 0`、`get 2`、`delete`
  final List<String> deleted = [];

  /// 每次调用前执行；抛异常就算这次调用失败。参数是 `put`/`get`/`delete` 和块序号（delete 为 -1）。
  Future<void> Function(String op, int index)? before;

  /// 下载时改写返回的内容（模拟传输中损坏）。
  Uint8List Function(int index, Uint8List sealed)? tamper;

  int count(String call) => calls.where((c) => c == call).length;

  FileRelayAuth? lastAuth;

  @override
  Future<void> putChunk(
    String fileId,
    int index,
    Uint8List sealed,
    FileRelayAuth auth,
  ) async {
    lastAuth = auth;
    calls.add('put $index');
    await before?.call('put', index);
    files.putIfAbsent(fileId, () => {})[index] = Uint8List.fromList(sealed);
  }

  @override
  Future<Uint8List> getChunk(
    String fileId,
    int index,
    FileRelayAuth auth,
  ) async {
    lastAuth = auth;
    calls.add('get $index');
    await before?.call('get', index);
    final sealed = files[fileId]?[index];
    if (sealed == null) throw const FileRelayException(404, 'not-found');
    final copy = Uint8List.fromList(sealed);
    return tamper?.call(index, copy) ?? copy;
  }

  @override
  Future<void> deleteFile(String fileId, FileRelayAuth auth) async {
    lastAuth = auth;
    calls.add('delete');
    await before?.call('delete', -1);
    files.remove(fileId);
    deleted.add(fileId);
  }
}

/// 可重复的伪随机内容，避免各块内容相同。
Uint8List pattern(int length, {int seed = 1}) {
  final bytes = Uint8List(length);
  var x = seed;
  for (var i = 0; i < length; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    bytes[i] = x >> 16;
  }
  return bytes;
}
