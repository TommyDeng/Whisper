import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/files/file_cipher.dart';
import 'package:whisper/files/file_relay_api.dart';

const _fileId = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _auth = FileRelayAuth(sessionId: 'AAAAAAAAAAAAAAAAAAAAAA', peer: 'a');

void main() {
  late HttpServer server;
  late HttpFileRelay relay;
  late Future<void> Function(HttpRequest request) handler;
  final seen = <String>[];

  Future<void> reply(HttpRequest request, int status, [Object? body]) async {
    request.response.statusCode = status;
    if (body is List<int>) {
      request.response.headers.contentType = ContentType.binary;
      request.response.add(body);
    } else if (body != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
    }
    await request.response.close();
  }

  setUp(() async {
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      seen.add('${request.method} ${request.uri.path}');
      try {
        await handler(request);
      } catch (_) {
        // 客户端提前断开
      }
    });
    relay = HttpFileRelay(
      Uri.parse('ws://127.0.0.1:${server.port}/ignored?x=1'),
      timeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async {
    relay.close();
    await server.close(force: true);
  });

  TypeMatcher<FileRelayException> relayError(int status, String code) => isA<FileRelayException>()
      .having((e) => e.status, 'status', status)
      .having((e) => e.code, 'code', code);

  test('putChunk：PUT 到 /file/<id>/<index>，正文原样，201 成功', () async {
    final sent = Uint8List.fromList(List.generate(5000, (i) => i % 251));
    late List<int> received;
    late String? contentType;
    late String? authorization;
    handler = (request) async {
      contentType = request.headers.contentType?.mimeType;
      authorization = request.headers.value('authorization');
      received = await request.fold<List<int>>([], (all, part) => all..addAll(part));
      await reply(request, 201, {'ok': true});
    };
    await relay.putChunk(_fileId, 7, sent, _auth);
    expect(seen, ['PUT /file/$_fileId/7']);
    expect(received, sent);
    expect(contentType, 'application/octet-stream');
    expect(authorization, 'Whisper AAAAAAAAAAAAAAAAAAAAAA a');
  });

  test('putChunk：409 chunk-exists 算成功，其它状态抛异常', () async {
    handler = (request) async {
      await request.drain<void>();
      await reply(request, 409, {'ok': false, 'error': 'chunk-exists'});
    };
    await relay.putChunk(_fileId, 0, Uint8List(10), _auth);

    handler = (request) async {
      await request.drain<void>();
      await reply(request, 413, {'ok': false, 'error': 'chunk-too-large'});
    };
    await expectLater(
      relay.putChunk(_fileId, 0, Uint8List(10), _auth),
      throwsA(relayError(413, 'chunk-too-large')),
    );

    handler = (request) async {
      await request.drain<void>();
      await reply(request, 409, {'ok': false, 'error': 'something-else'});
    };
    await expectLater(
      relay.putChunk(_fileId, 0, Uint8List(10), _auth),
      throwsA(relayError(409, 'something-else')),
    );
  });

  test('getChunk：返回正文；404 抛 not-found', () async {
    final body = Uint8List.fromList(List.generate(70000, (i) => i % 256));
    handler = (request) => reply(request, 200, body);
    expect(await relay.getChunk(_fileId, 3, _auth), body);
    expect(seen, ['GET /file/$_fileId/3']);

    handler = (request) => reply(request, 404, {'ok': false, 'error': 'not-found'});
    await expectLater(relay.getChunk(_fileId, 3, _auth), throwsA(relayError(404, 'not-found')));
  });

  test('getChunk：超过一块的响应被拒绝（声明长度或实际长度）', () async {
    const limit = FileCipher.chunkSize + FileCipher.tagLength;
    handler = (request) => reply(request, 200, Uint8List(limit));
    expect(await relay.getChunk(_fileId, 0, _auth), hasLength(limit));

    handler = (request) => reply(request, 200, Uint8List(limit + 1));
    await expectLater(relay.getChunk(_fileId, 0, _auth), throwsA(relayError(200, 'too-large')));

    // 不声明长度（分块传输）
    handler = (request) async {
      request.response.statusCode = 200;
      for (var i = 0; i < 5; i++) {
        request.response.add(Uint8List(300 * 1024));
        await request.response.flush();
      }
      await request.response.close();
    };
    await expectLater(relay.getChunk(_fileId, 0, _auth), throwsA(relayError(200, 'too-large')));
  });

  test('连续请求（含被拒绝的超长响应之后）都能正常完成', () async {
    handler = (request) async {
      await request.drain<void>();
      if (request.method == 'PUT') return reply(request, 201, {'ok': true});
      final index = int.parse(request.uri.pathSegments.last);
      return reply(request, 200, Uint8List(index == 1 ? HttpFileRelay.maxSealedBytes + 1 : 10 + index));
    };
    await relay.putChunk(_fileId, 0, Uint8List(100), _auth);
    expect(await relay.getChunk(_fileId, 0, _auth), hasLength(10));
    await expectLater(relay.getChunk(_fileId, 1, _auth), throwsA(relayError(200, 'too-large')));
    expect(await relay.getChunk(_fileId, 2, _auth), hasLength(12));
    await relay.putChunk(_fileId, 3, Uint8List(100), _auth);
    expect(seen, hasLength(5));
  });

  test('deleteFile：DELETE 到 /file/<id>，非 200 抛异常', () async {
    handler = (request) => reply(request, 200, {'ok': true});
    await relay.deleteFile(_fileId, _auth);
    expect(seen, ['DELETE /file/$_fileId']);

    handler = (request) => reply(request, 400, {'ok': false, 'error': 'bad-file-id'});
    await expectLater(relay.deleteFile(_fileId, _auth), throwsA(relayError(400, 'bad-file-id')));
  });

  test('错误响应读不出 error 字段时 code 为空串', () async {
    handler = (request) => reply(request, 502, utf8.encode('<html>bad gateway</html>'));
    await expectLater(
      relay.getChunk(_fileId, 0, _auth),
      throwsA(relayError(502, '').having((e) => e.isTransient, 'isTransient', isTrue)),
    );
  });

  test('连不上或超时抛 network', () async {
    handler = (request) async {
      await Future<void>.delayed(const Duration(seconds: 5));
    };
    final slow = HttpFileRelay(
      Uri.parse('http://127.0.0.1:${server.port}'),
      timeout: const Duration(milliseconds: 200),
    );
    await expectLater(slow.getChunk(_fileId, 0, _auth), throwsA(relayError(0, 'network')));
    // 超时后连接被丢弃，下一次请求照常
    handler = (request) => reply(request, 200, Uint8List(3));
    expect(await slow.getChunk(_fileId, 0, _auth), hasLength(3));
    slow.close();

    final port = server.port;
    await server.close(force: true);
    final closed = HttpFileRelay(Uri.parse('ws://127.0.0.1:$port'));
    await expectLater(
      closed.getChunk(_fileId, 0, _auth),
      throwsA(relayError(0, 'network').having((e) => e.isNetwork, 'isNetwork', isTrue)),
    );
  });


  test('鉴权失败和配额超额按响应码抛异常', () async {
    handler = (request) async {
      expect(request.headers.value('authorization'), _auth.headerValue);
      await request.drain<void>();
      await reply(request, 401, {'ok': false, 'error': 'unauthorized'});
    };
    await expectLater(relay.putChunk(_fileId, 0, Uint8List(10), _auth), throwsA(relayError(401, 'unauthorized')));

    handler = (request) async {
      await request.drain<void>();
      await reply(request, 403, {'ok': false, 'error': 'forbidden'});
    };
    await expectLater(relay.getChunk(_fileId, 0, _auth), throwsA(relayError(403, 'forbidden')));

    handler = (request) async {
      await request.drain<void>();
      await reply(request, 413, {'ok': false, 'error': 'quota-exceeded'});
    };
    await expectLater(
      relay.putChunk(_fileId, 0, Uint8List(10), _auth),
      throwsA(relayError(413, 'quota-exceeded').having((e) => e.isTransient, 'isTransient', isFalse)),
    );
  });

  test('地址换协议：wss → https，不支持的协议抛 ArgumentError', () {
    HttpFileRelay(Uri.parse('wss://relay.example'));
    HttpFileRelay(Uri.parse('https://relay.example'));
    expect(() => HttpFileRelay(Uri.parse('ftp://relay.example')), throwsArgumentError);
  });
}
