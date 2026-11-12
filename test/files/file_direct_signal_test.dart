import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/call/call_signal.dart';
import 'package:whisper/files/file_cipher.dart';
import 'package:whisper/files/file_direct_signal.dart';
import 'package:whisper/files/file_offer.dart';

void main() {
  FileOffer offer({int? size}) => FileOffer(
    fileId: FileOffer.newFileId(),
    name: '电影.mkv',
    size: size ?? FileCipher.maxFileBytes + 1,
    keys: FileKeys.random(),
    hash: Uint8List.fromList(List.generate(32, (i) => i)),
    via: FileTransferVia.direct,
  );

  test('offer / answer / candidate / end 往返', () {
    final file = offer();
    final offerSignal = FileDirectSignal.offer('xfer-1', 'v=0\r\n', file);
    final decoded = FileDirectSignal.decode(offerSignal.encode())!;
    expect(decoded.kind, FileDirectSignal.kindOffer);
    expect(decoded.xferId, 'xfer-1');
    expect(decoded.sdp, 'v=0\r\n');
    expect(decoded.file!.fileId, file.fileId);
    expect(decoded.file!.isDirect, isTrue);
    expect(decoded.file!.size, file.size);

    final answer = FileDirectSignal.decode(
      FileDirectSignal.answer('xfer-1', 'v=1\r\n').encode(),
    )!;
    expect(answer.kind, FileDirectSignal.kindAnswer);
    expect(answer.sdp, 'v=1\r\n');

    const candidate = CallCandidate(
      'candidate:1',
      sdpMid: '0',
      sdpMLineIndex: 0,
    );
    final cand = FileDirectSignal.decode(
      FileDirectSignal.candidate('xfer-1', candidate).encode(),
    )!;
    expect(cand.candidate, candidate);

    final end = FileDirectSignal.decode(
      FileDirectSignal.end('xfer-1', FileDirectSignal.reasonNoDirect).encode(),
    )!;
    expect(end.reason, FileDirectSignal.reasonNoDirect);
  });

  test('decode 拒绝不合格内容', () {
    final goodFile = jsonDecode(offer().encode());
    final good = {
      'k': 'offer',
      'xfer': 'xfer-1',
      'sdp': 'v=0',
      'file': goodFile,
    };
    final bad = <String, String>{
      '不是 JSON': 'not json',
      '缺 xfer': jsonEncode({'k': 'offer', 'sdp': 'v=0', 'file': goodFile}),
      'xfer 过长': jsonEncode({...good, 'xfer': 'x' * 65}),
      'sdp 空': jsonEncode({...good, 'sdp': ''}),
      '没有 file': jsonEncode({'k': 'offer', 'xfer': 'xfer-1', 'sdp': 'v=0'}),
      '中转 file': jsonEncode({
        ...good,
        'file': jsonDecode(
          FileOffer(
            fileId: FileOffer.newFileId(),
            name: 'a.bin',
            size: 10,
            keys: FileKeys.random(),
            hash: Uint8List(32),
          ).encode(),
        ),
      }),
      '不认识的种类': jsonEncode({'k': 'ringing', 'xfer': 'xfer-1'}),
      'end 没有 reason': jsonEncode({'k': 'end', 'xfer': 'xfer-1'}),
    };
    for (final entry in bad.entries) {
      expect(FileDirectSignal.decode(entry.value), isNull, reason: entry.key);
    }
  });
}
