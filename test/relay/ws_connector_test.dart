import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/relay/relay_transport.dart';
import 'package:whisper/relay/ws_connector.dart';

void main() {
  late HttpServer server;
  late Uri base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('ws://127.0.0.1:${server.port}');
    server.listen((request) async {
      switch (request.uri.path) {
        case '/echo':
          final socket = await WebSocketTransformer.upgrade(request);
          socket.add(jsonEncode({'hello': request.uri.queryParameters['peer']}));
          socket.listen((data) {
            if (data == 'kick') {
              socket.close(4001, 'replaced');
            } else {
              socket.add('echo:$data');
            }
          });
        case '/used':
          request.response
            ..statusCode = 410
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'ok': false, 'error': 'invite-used'}));
          await request.response.close();
        default:
          request.response
            ..statusCode = 500
            ..write('oops');
          await request.response.close();
      }
    });
  });

  tearDown(() => server.close(force: true));

  test('连接、收发文本帧、主动关闭后帧流结束', () async {
    final connection = await connectWebSocket(base.replace(path: '/echo', query: 'peer=a'));
    final frames = StreamIterator(connection.frames);

    expect(await frames.moveNext(), isTrue);
    expect(jsonDecode(frames.current), {'hello': 'a'});

    connection.send('ping');
    expect(await frames.moveNext(), isTrue);
    expect(frames.current, 'echo:ping');

    await connection.close();
    expect(await frames.moveNext(), isFalse);
    expect(connection.closeCode, 1000);
    expect(() => connection.send('late'), throwsStateError);
    await connection.close();
  });

  test('对端关闭时帧流结束，并带上关闭码', () async {
    final connection = await connectWebSocket(base.replace(path: '/echo'));
    final frames = StreamIterator(connection.frames);
    expect(await frames.moveNext(), isTrue);

    connection.send('kick');
    expect(await frames.moveNext(), isFalse);
    expect(connection.closeCode, 4001);
  });

  test('升级被拒绝时抛 RelayRejected，带状态码和错误码', () async {
    await expectLater(
      connectWebSocket(base.replace(path: '/used')),
      throwsA(isA<RelayRejected>()
          .having((e) => e.status, 'status', 410)
          .having((e) => e.error, 'error', 'invite-used')),
    );
    await expectLater(
      connectWebSocket(base.replace(path: '/other')),
      throwsA(isA<RelayRejected>()
          .having((e) => e.status, 'status', 500)
          .having((e) => e.error, 'error', isNull)),
    );
  });

  test('连不上时抛异常（不是 RelayRejected）', () async {
    final port = server.port;
    await server.close(force: true);
    await expectLater(
      connectWebSocket(Uri.parse('ws://127.0.0.1:$port/echo')),
      throwsA(isNot(isA<RelayRejected>())),
    );
  });
}
