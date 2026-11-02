import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_webrtc_spike/transfer/direct_channel.dart';
import 'package:whisper_webrtc_spike/transfer/frames.dart';

void main() {
  test('direct file key is bound to the DTLS fingerprint pair', () {
    const a = 'sha-256 AA:BB';
    const b = 'sha-256 CC:DD';
    expect(directFileKey(a, b), directFileKey(b, a));
    expect(directFileKey(a, b), isNot(directFileKey(a, 'sha-256 EE:FF')));
  });

  test('TCP side channel rejects a bad key and accepts an encrypted file', () async {
    final key = directFileKey('sha-256 AA:11', 'sha-256 BB:22');
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final bound = '127.0.0.1:${server.port}';
    final accepted = server.first.then((socket) => DirectLink.accept(socket: socket, key: key, boundAddress: bound));
    final client = await DirectLink.connect(host: '127.0.0.1', port: server.port, key: key);
    final link = await accepted;

    final plain = Uint8List.fromList(List<int>.generate(200000, (index) => index % 251));
    final payloads = [plain];
    final digest = ChunkAssembler.hashPayloads(payloads);
    final received = link.receiveFile();
    await client.sendFile(id: 'file1', name: 'a.bin', payloads: payloads, sha256Hex: digest, chunkSize: 64 * 1024);
    final result = await received;
    expect(result.ok, isTrue);
    expect(result.bytes, plain);
    expect(result.sha256Hex, digest);
    await client.close();
    await link.close();
    await server.close();

    final badServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final serverFailed = Completer<Object>();
    badServer.first.then((socket) {
      return DirectLink.accept(
        socket: socket,
        key: directFileKey('sha-256 NO:PE', 'sha-256 BB:22'),
        boundAddress: '127.0.0.1:${badServer.port}',
      );
    }).then((_) {}, onError: (Object error, StackTrace _) {
      if (!serverFailed.isCompleted) serverFailed.complete(error);
    });
    await expectLater(
      DirectLink.connect(host: '127.0.0.1', port: badServer.port, key: key),
      throwsA(isA<StateError>()),
    );
    expect(await serverFailed.future, isA<StateError>());
    await badServer.close();
  });
}
