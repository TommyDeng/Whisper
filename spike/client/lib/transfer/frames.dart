import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

/// Binary file frame: `WSP1` + uint32 big-endian sequence + payload.
/// Sequence numbers let the receiver place chunks that arrive out of order
/// and ask for the ones that never arrived.
const frameHeaderLength = 8;

Uint8List encodeChunkFrame(int sequence, Uint8List payload) {
  if (sequence < 0 || sequence > 0xFFFFFFFF) {
    throw ArgumentError.value(sequence, 'sequence');
  }
  final out = Uint8List(frameHeaderLength + payload.length);
  out[0] = 0x57;
  out[1] = 0x53;
  out[2] = 0x50;
  out[3] = 0x31;
  out[4] = (sequence >> 24) & 0xff;
  out[5] = (sequence >> 16) & 0xff;
  out[6] = (sequence >> 8) & 0xff;
  out[7] = sequence & 0xff;
  out.setRange(frameHeaderLength, out.length, payload);
  return out;
}

class DecodedFrame {
  const DecodedFrame(this.sequence, this.payload);

  final int sequence;
  final Uint8List payload;
}

DecodedFrame? decodeChunkFrame(Uint8List bytes) {
  if (bytes.length < frameHeaderLength) return null;
  if (bytes[0] != 0x57 || bytes[1] != 0x53 || bytes[2] != 0x50 || bytes[3] != 0x31) {
    return null;
  }
  final sequence = (bytes[4] << 24) | (bytes[5] << 16) | (bytes[6] << 8) | bytes[7];
  return DecodedFrame(sequence, Uint8List.sublistView(bytes, frameHeaderLength));
}

int chunkCountFor(int size, int chunkSize) {
  if (chunkSize <= 0) throw ArgumentError.value(chunkSize, 'chunkSize');
  if (size <= 0) return 0;
  return (size + chunkSize - 1) ~/ chunkSize;
}

List<Uint8List> splitPayloads(List<int> data, int chunkSize) {
  final payloads = <Uint8List>[];
  var offset = 0;
  while (offset < data.length) {
    final end = offset + chunkSize < data.length ? offset + chunkSize : data.length;
    payloads.add(Uint8List.fromList(data.sublist(offset, end)));
    offset = end;
  }
  return payloads;
}

class ChunkAssembler {
  ChunkAssembler({required this.size, required this.chunkSize}) {
    if (chunkSize <= 0) throw ArgumentError.value(chunkSize, 'chunkSize');
    if (size < 0) throw ArgumentError.value(size, 'size');
  }

  final int size;
  final int chunkSize;
  final Map<int, Uint8List> _frames = {};

  int get chunkCount => chunkCountFor(size, chunkSize);

  int get receivedPayloadBytes {
    var total = 0;
    for (final frame in _frames.values) {
      total += frame.length;
    }
    return total;
  }

  int expectedLength(int sequence) {
    if (sequence < 0 || sequence >= chunkCount) return -1;
    if (sequence == chunkCount - 1) {
      final remainder = size % chunkSize;
      return remainder == 0 ? chunkSize : remainder;
    }
    return chunkSize;
  }

  /// Returns true when this call stored a new, well-formed frame.
  bool addFrame(DecodedFrame frame) {
    final expected = expectedLength(frame.sequence);
    if (expected < 0 || frame.payload.length != expected) return false;
    if (_frames.containsKey(frame.sequence)) return false;
    _frames[frame.sequence] = Uint8List.fromList(frame.payload);
    return true;
  }

  List<int> missingSequences() {
    final missing = <int>[];
    for (var sequence = 0; sequence < chunkCount; sequence++) {
      if (!_frames.containsKey(sequence)) missing.add(sequence);
    }
    return missing;
  }

  bool get complete => missingSequences().isEmpty;

  /// SHA-256 of payloads in sequence order, with no frame headers.
  static String hashPayloads(Iterable<Uint8List> payloads) {
    final output = AccumulatorSink<Digest>();
    final hash = sha256.startChunkedConversion(output);
    for (final payload in payloads) {
      hash.add(payload);
    }
    hash.close();
    output.close();
    return output.events.single.toString();
  }

  /// Writes every stored frame in order. Only valid once [complete] is true.
  String writeAndHash(Sink<List<int>> sink) {
    final output = AccumulatorSink<Digest>();
    final hash = sha256.startChunkedConversion(output);
    for (var sequence = 0; sequence < chunkCount; sequence++) {
      final frame = _frames[sequence];
      if (frame == null) {
        throw StateError('缺少分块 $sequence');
      }
      hash.add(frame);
      sink.add(frame);
    }
    hash.close();
    output.close();
    return output.events.single.toString();
  }
}
