import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_webrtc_spike/transfer/bytes.dart';
import 'package:whisper_webrtc_spike/transfer/chunk_pump.dart';
import 'package:whisper_webrtc_spike/transfer/frames.dart';
import 'package:whisper_webrtc_spike/transfer/messages.dart';

void main() {
  test('round-trips text and file messages', () {
    expect(parseSpikeMessage(encodeText('你好')), isA<TextSpike>().having((m) => m.body, 'body', '你好'));
    final start = parseSpikeMessage(
      encodeFileStart(id: 'abc', name: 'a.bin', size: 3, chunkSize: 2, chunks: 2),
    );
    expect(start, isA<FileStartSpike>().having((message) => message.chunks, 'chunks', 2));
    expect(parseSpikeMessage(encodeTextAck('spike-hello')), isA<TextAckSpike>());
    expect(parseSpikeMessage(encodeFileStartAck('abc')), isA<FileStartAckSpike>());
    expect(
      parseSpikeMessage(encodeFileNak(id: 'abc', missing: [1, 4])),
      isA<FileNakSpike>().having((message) => message.missing, 'missing', [1, 4]),
    );
    final end = parseSpikeMessage(encodeFileEnd(id: 'abc', sha256: 'ff', submitMillis: 12));
    expect(end, isA<FileEndSpike>().having((m) => m.submitMillis, 'submit', 12));
    final result = parseSpikeMessage(
      encodeFileResult(id: 'abc', ok: true, bytes: 3, millis: 9, sha256: 'ff'),
    );
    expect(result, isA<FileResultSpike>().having((m) => m.ok, 'ok', isTrue));
    expect(parseSpikeMessage('not-json'), isA<UnknownSpike>());
    expect(safeFileName('../etc/passwd'), 'passwd');
    expect(safeFileName(''), 'received.bin');
  });

  test('xorshift stream length is stable', () async {
    final first = await xorshiftBytes(1000).fold<int>(0, (sum, chunk) => sum + chunk.length);
    final again = await xorshiftBytes(1000).fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final third = await xorshiftBytes(1000).fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    expect(first, 1000);
    expect(again, third);
  });

  test('chunk pump splits writes and waits when the buffer is high', () async {
    final sent = <int>[];
    var buffered = 0;
    var waits = 0;
    final pump = ChunkPump(
      chunkSize: 4,
      highWater: 8,
      lowWater: 0,
      sendBinary: (bytes) async {
        sent.add(bytes.length);
        buffered += bytes.length;
      },
      bufferedAmount: () async => buffered,
      waitForDrain: () async {
        waits += 1;
        buffered = 0;
      },
    );
    await pump.send(Stream<List<int>>.value(Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8, 9])));
    expect(sent, [4, 4, 1]);
    expect(waits, greaterThan(0));
    expect(buffered, 0);
  });

  test('sequence frames survive reorder, a drop, and retransmission', () {
    final original = Uint8List.fromList(List<int>.generate(100, (index) => index));
    final payloads = splitPayloads(original, 16);
    expect(payloads, hasLength(chunkCountFor(original.length, 16)));
    final assembler = ChunkAssembler(size: original.length, chunkSize: 16);
    final wire = [for (var sequence = 0; sequence < payloads.length; sequence++) encodeChunkFrame(sequence, payloads[sequence])];
    final early = decodeChunkFrame(wire[4])!;
    expect(assembler.addFrame(early), isTrue);
    for (var sequence = payloads.length - 1; sequence >= 0; sequence--) {
      if (sequence == 2 || sequence == 4) continue;
      final frame = decodeChunkFrame(wire[sequence])!;
      expect(assembler.addFrame(frame), isTrue);
    }
    expect(assembler.addFrame(decodeChunkFrame(wire[0])!), isFalse);
    expect(assembler.missingSequences(), [2]);
    expect(assembler.receivedPayloadBytes, original.length - payloads[2].length);
    expect(assembler.addFrame(decodeChunkFrame(wire[2])!), isTrue);
    expect(assembler.complete, isTrue);
    final rebuilt = <int>[];
    final digest = assembler.writeAndHash(_ByteSink(rebuilt));
    expect(rebuilt, original);
    expect(digest, ChunkAssembler.hashPayloads(payloads));
    expect(decodeChunkFrame(Uint8List(3)), isNull);
  });
}

class _ByteSink implements Sink<List<int>> {
  _ByteSink(this.bytes);

  final List<int> bytes;

  @override
  void add(List<int> data) {
    bytes.addAll(data);
  }

  @override
  void close() {}
}
