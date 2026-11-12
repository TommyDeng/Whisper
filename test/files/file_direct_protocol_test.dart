import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/files/file_cipher.dart';
import 'package:whisper/files/file_direct_protocol.dart';

void main() {
  test('控制消息往返', () {
    expect(FileDirectControl.parse(FileDirectProtocol.start(3))!.index, 3);
    expect(FileDirectControl.parse(FileDirectProtocol.ack(2))!.index, 2);
    expect(
      FileDirectControl.parse(FileDirectProtocol.done())!.type,
      FileDirectProtocol.typeDone,
    );
    expect(
      FileDirectControl.parse(FileDirectProtocol.fail('corrupt'))!.reason,
      'corrupt',
    );
    expect(
      FileDirectControl.parse(FileDirectProtocol.abort())!.type,
      FileDirectProtocol.typeAbort,
    );
    expect(FileDirectControl.parse('not json'), isNull);
    expect(FileDirectControl.parse('{"t":"start","next":-1}'), isNull);
    expect(FileDirectControl.parse('{"t":"unknown"}'), isNull);
  });

  test('密文块分片再拼回', () {
    final sealed = Uint8List.fromList(
      List.generate(FileDirectProtocol.fragmentSize * 2 + 7, (i) => i & 0xff),
    );
    final frames = FileDirectProtocol.fragments(4, sealed);
    expect(frames.length, 3);
    final assembler = ChunkReassembler();
    expect(assembler.add(frames[0]), isNull);
    expect(assembler.add(frames[1]), isNull);
    expect(assembler.add(frames[2]), sealed);
    expect(assembler.chunkIndex, isNull);
  });

  test('空密文块也能拼回', () {
    final frames = FileDirectProtocol.fragments(0, Uint8List(0));
    expect(frames, hasLength(1));
    expect(ChunkReassembler().add(frames.single), Uint8List(0));
  });

  test('不合格分片被忽略', () {
    final sealed = Uint8List.fromList(
      List.generate(FileDirectProtocol.fragmentSize + 10, (i) => 1),
    );
    final frames = FileDirectProtocol.fragments(1, sealed);
    expect(frames, hasLength(2));
    final assembler = ChunkReassembler();
    expect(assembler.add(Uint8List(4)), isNull);
    expect(
      assembler.add(Uint8List.fromList([0, 0, 0, 0, ...frames.first.skip(4)])),
      isNull,
    );
    final bad = Uint8List.fromList(frames.first);
    ByteData.sublistView(bad)
        .setUint32(12, FileCipher.chunkSize + FileCipher.tagLength + 1);
    expect(assembler.add(bad), isNull);
    expect(assembler.add(frames.first), isNull);
    expect(assembler.add(frames.first), isNull); // 重复 offset 忽略
    expect(assembler.add(frames.last), sealed);
  });
}
