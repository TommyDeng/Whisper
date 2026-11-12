/// 数据通道上的分片与控制消息。约定见 docs/file-direct.md。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'file_cipher.dart';

class FileDirectProtocol {
  FileDirectProtocol._();

  static const int fragmentSize = 16 * 1024;
  static const int headerLength = 16;
  static const int highWater = 1024 * 1024;
  static const int lowWater = 256 * 1024;

  static const String typeStart = 'start';
  static const String typeAck = 'ack';
  static const String typeDone = 'done';
  static const String typeFail = 'fail';
  static const String typeAbort = 'abort';

  static String start(int next) => jsonEncode({'t': typeStart, 'next': next});

  static String ack(int index) => jsonEncode({'t': typeAck, 'i': index});

  static String done() => jsonEncode({'t': typeDone});

  static String fail(String reason) =>
      jsonEncode({'t': typeFail, 'reason': reason});

  static String abort() => jsonEncode({'t': typeAbort});

  /// 把一块密文切成若干条数据通道消息。
  static List<Uint8List> fragments(int chunkIndex, Uint8List sealed) {
    if (chunkIndex < 0) {
      throw ArgumentError.value(chunkIndex, 'chunkIndex');
    }
    if (sealed.length > FileCipher.chunkSize + FileCipher.tagLength) {
      throw ArgumentError.value(sealed.length, 'sealed', '密文块过长');
    }
    if (sealed.isEmpty) {
      return [_frame(chunkIndex, 0, 0, Uint8List(0))];
    }
    final out = <Uint8List>[];
    var offset = 0;
    while (offset < sealed.length) {
      final end = offset + fragmentSize < sealed.length
          ? offset + fragmentSize
          : sealed.length;
      out.add(
        _frame(
          chunkIndex,
          offset,
          sealed.length,
          Uint8List.sublistView(sealed, offset, end),
        ),
      );
      offset = end;
    }
    return out;
  }

  static Uint8List _frame(
    int chunkIndex,
    int offset,
    int total,
    Uint8List payload,
  ) {
    final out = Uint8List(headerLength + payload.length);
    out[0] = 0x57;
    out[1] = 0x46;
    out[2] = 0x01;
    out[3] = 0x00;
    final data = ByteData.sublistView(out);
    data.setUint32(4, chunkIndex);
    data.setUint32(8, offset);
    data.setUint32(12, total);
    out.setRange(headerLength, out.length, payload);
    return out;
  }
}

/// 一条从数据通道收到的控制消息。解析失败为 null。
class FileDirectControl {
  const FileDirectControl(this.type, {this.index, this.reason});

  final String type;
  final int? index;
  final String? reason;

  static FileDirectControl? parse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    final type = json['t'];
    if (type is! String) return null;
    switch (type) {
      case FileDirectProtocol.typeStart:
        final next = json['next'];
        if (next is! int || next < 0) return null;
        return FileDirectControl(type, index: next);
      case FileDirectProtocol.typeAck:
        final index = json['i'];
        if (index is! int || index < 0) return null;
        return FileDirectControl(type, index: index);
      case FileDirectProtocol.typeDone:
        return const FileDirectControl(FileDirectProtocol.typeDone);
      case FileDirectProtocol.typeFail:
        final reason = json['reason'];
        if (reason is! String || reason.isEmpty || reason.length > 32) {
          return null;
        }
        return FileDirectControl(type, reason: reason);
      case FileDirectProtocol.typeAbort:
        return const FileDirectControl(FileDirectProtocol.typeAbort);
      default:
        return null;
    }
  }
}

/// 把同一密文块的分片重新拼起来。一次只拼一块。
class ChunkReassembler {
  int? _index;
  int? _total;
  final _parts = <int, Uint8List>{}; // offset → payload
  int _have = 0;

  /// 吃进一个分片。分片不合格返回 null 且不动状态；一块收齐则返回完整密文并清空。
  Uint8List? add(Uint8List frame) {
    if (frame.length < FileDirectProtocol.headerLength) return null;
    if (frame[0] != 0x57 || frame[1] != 0x46 || frame[2] != 0x01) return null;
    final data = ByteData.sublistView(frame);
    final index = data.getUint32(4);
    final offset = data.getUint32(8);
    final total = data.getUint32(12);
    final payload = Uint8List.sublistView(
      frame,
      FileDirectProtocol.headerLength,
    );
    const max = FileCipher.chunkSize + FileCipher.tagLength;
    if (total > max) return null;
    if (offset + payload.length > total) return null;
    if (_index != null && (_index != index || _total != total)) return null;
    if (_parts.containsKey(offset)) return null;
    _index = index;
    _total = total;
    _parts[offset] = Uint8List.fromList(payload);
    _have += payload.length;
    if (_have < total) return null;
    if (_have != total) {
      _reset();
      return null;
    }
    final sealed = Uint8List(total);
    var filled = 0;
    final offsets = _parts.keys.toList()..sort();
    for (final start in offsets) {
      if (start != filled) {
        _reset();
        return null;
      }
      final part = _parts[start]!;
      sealed.setRange(start, start + part.length, part);
      filled += part.length;
    }
    _reset();
    if (filled != total) return null;
    return sealed;
  }

  int? get chunkIndex => _index;

  void _reset() {
    _index = null;
    _total = null;
    _parts.clear();
    _have = 0;
  }
}
