import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/relay/relay_transport.dart';
import 'package:whisper/relay/session_client.dart';

import 'fake_relay.dart';

const _sessionId = 'AAAAAAAAAAAAAAAAAAAAAA';
const _longInterval = Duration(hours: 1);

SessionClient _client(
  FakeRelay relay, {
  String peer = 'a',
  RelayMessageHandler? onMessage,
  List<Duration> backoff = const [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ],
  Duration pingInterval = _longInterval,
  Duration pongTimeout = const Duration(seconds: 10),
}) {
  return SessionClient(
    baseUri: Uri.parse('wss://relay.test'),
    sessionId: _sessionId,
    peer: peer,
    connector: relay.connect,
    onMessage: onMessage ?? (_) async {},
    backoff: backoff,
    pingInterval: pingInterval,
    pongTimeout: pongTimeout,
  );
}

Map<String, dynamic> _welcome({bool peerOnline = false, String peer = 'a'}) =>
    {'type': 'welcome', 'peer': peer, 'peerOnline': peerOnline};

/// 启动并完成握手，返回这条连接。
FakeConnection _connect(FakeAsync async, FakeRelay relay, SessionClient client,
    {bool peerOnline = false}) {
  client.start();
  async.flushMicrotasks();
  final connection = relay.last;
  connection.push(_welcome(peerOnline: peerOnline));
  async.flushMicrotasks();
  return connection;
}

List<T> _collect<T>(Stream<T> stream) {
  final events = <T>[];
  stream.listen(events.add);
  return events;
}

void main() {
  group('连接', () {
    test('连接到 /session/<id>?peer=<peer>，收到 welcome 后才算已连接', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay, peer: 'b');
        final states = _collect(client.states);

        expect(client.state, SessionLinkState.disconnected);
        client.start();
        async.flushMicrotasks();

        expect(relay.attempts, hasLength(1));
        final uri = relay.attempts.single;
        expect(uri.scheme, 'wss');
        expect(uri.host, 'relay.test');
        expect(uri.path, '/session/$_sessionId');
        expect(uri.queryParameters, {'peer': 'b'});
        expect(client.state, SessionLinkState.connecting);

        relay.last.push(_welcome(peer: 'b'));
        async.flushMicrotasks();
        expect(client.state, SessionLinkState.connected);
        expect(states, [SessionLinkState.connecting, SessionLinkState.connected]);

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('重复调用 start 不会建立第二条连接', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        _connect(async, relay, client);
        client.start();
        async.flushMicrotasks();
        expect(relay.attempts, hasLength(1));
        client.stop();
        async.flushMicrotasks();
      });
    });

    test('对方在线状态来自 welcome 和 peer-online / peer-offline', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        final changes = _collect(client.peerOnlineChanges);

        expect(client.peerOnline, isFalse);
        final connection = _connect(async, relay, client, peerOnline: true);
        expect(client.peerOnline, isTrue);

        connection.push({'type': 'peer-online'});
        async.flushMicrotasks();
        connection.push({'type': 'peer-offline'});
        async.flushMicrotasks();
        expect(client.peerOnline, isFalse);
        connection.push({'type': 'peer-online'});
        async.flushMicrotasks();
        expect(client.peerOnline, isTrue);

        connection.drop();
        async.flushMicrotasks();
        expect(client.peerOnline, isFalse);
        expect(changes, [true, false, true, false]);

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('忽略畸形帧和不认识的帧', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final handled = <String>[];
        final client = _client(relay, onMessage: (m) async => handled.add(m.id));
        final errors = _collect(client.errors);
        final connection = _connect(async, relay, client);

        connection.pushRaw('not json');
        connection.pushRaw('[1,2,3]');
        connection.pushRaw('"text"');
        connection.push({'type': 'something-new', 'id': 'x'});
        connection.push({'type': 'msg', 'id': 42, 'payload': 'p', 'ts': 1});
        connection.push({'type': 'msg', 'id': 'm1', 'payload': 7, 'ts': 1});
        connection.push({'no-type': true});
        connection.push({'type': 'msg', 'id': 'ok', 'payload': 'p', 'ts': 5});
        async.flushMicrotasks();

        expect(client.state, SessionLinkState.connected);
        expect(handled, ['ok']);
        expect(errors, isEmpty);
        expect(connection.sentOfType('ack').map((f) => f['id']), ['ok']);

        client.stop();
        async.flushMicrotasks();
      });
    });
  });

  group('发送', () {
    test('已连接时立即发出，收到 stored 后从待确认列表移除', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        final stored = _collect(client.stored);
        final connection = _connect(async, relay, client);

        client.send('m1', 'payload-1');
        async.flushMicrotasks();
        expect(connection.sentOfType('msg'), [
          {'type': 'msg', 'id': 'm1', 'payload': 'payload-1'},
        ]);
        expect(client.pendingIds, ['m1']);

        connection.push({'type': 'stored', 'id': 'm1'});
        async.flushMicrotasks();
        expect(client.pendingIds, isEmpty);
        expect(stored, ['m1']);

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('未连接时排队，welcome 之后按顺序发出', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);

        client.send('m1', 'one');
        client.send('m2', 'two');
        expect(client.pendingIds, ['m1', 'm2']);

        client.start();
        async.flushMicrotasks();
        client.send('m3', 'three');
        async.flushMicrotasks();
        expect(relay.last.sent, isEmpty, reason: 'welcome 之前不应发送');

        relay.last.push(_welcome());
        async.flushMicrotasks();
        expect(relay.last.sentOfType('msg').map((f) => f['id']), ['m1', 'm2', 'm3']);
        expect(relay.last.sentOfType('msg').map((f) => f['payload']), ['one', 'two', 'three']);

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('同一个待确认的 id 重复 send 不会重复排队或重复发送', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        final connection = _connect(async, relay, client);

        client.send('m1', 'one');
        client.send('m1', 'one');
        async.flushMicrotasks();
        expect(connection.sentOfType('msg'), hasLength(1));
        expect(client.pendingIds, ['m1']);

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('断线重连后重发还没收到 stored 的消息，已确认的不重发', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        final first = _connect(async, relay, client);

        client.send('m1', 'one');
        client.send('m2', 'two');
        client.send('m3', 'three');
        async.flushMicrotasks();
        first.push({'type': 'stored', 'id': 'm2'});
        async.flushMicrotasks();

        first.drop();
        async.flushMicrotasks();
        client.send('m4', 'four');
        async.elapse(const Duration(seconds: 1));
        expect(relay.connections, hasLength(2));
        final second = relay.last;
        expect(second.sent, isEmpty);
        second.push(_welcome());
        async.flushMicrotasks();

        expect(second.sentOfType('msg').map((f) => f['id']), ['m1', 'm3', 'm4']);
        expect(client.pendingIds, ['m1', 'm3', 'm4']);

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('临时消息：未连接时返回 false 且不排队，已连接时带 ephemeral 发出', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        final dropped = _collect(client.dropped);

        expect(client.sendEphemeral('e0', 'signal'), isFalse);
        expect(client.pendingIds, isEmpty);

        final connection = _connect(async, relay, client);
        expect(connection.sent, isEmpty);
        expect(client.sendEphemeral('e1', 'signal'), isTrue);
        async.flushMicrotasks();
        expect(connection.sent, [
          {'type': 'msg', 'id': 'e1', 'payload': 'signal', 'ephemeral': true},
        ]);
        expect(client.pendingIds, isEmpty);

        connection.push({'type': 'dropped', 'id': 'e1'});
        async.flushMicrotasks();
        expect(dropped, ['e1']);

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('delivered 通过流通知', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        final delivered = _collect(client.delivered);
        final connection = _connect(async, relay, client);

        connection.push({'type': 'delivered', 'id': 'm9'});
        async.flushMicrotasks();
        expect(delivered, ['m9']);

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('error 帧通过流通知；不可重试的错误把消息移出待确认列表', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        final errors = _collect(client.errors);
        final connection = _connect(async, relay, client);

        client.send('m1', 'one');
        client.send('m2', 'two');
        client.send('m3', 'three');
        client.send('m4', 'four');
        async.flushMicrotasks();

        connection.push({'type': 'error', 'error': 'too-large', 'id': 'm1'});
        connection.push({'type': 'error', 'error': 'bad-payload', 'id': 'm2'});
        connection.push({'type': 'error', 'error': 'bad-id', 'id': 'm3'});
        connection.push({'type': 'error', 'error': 'queue-full', 'id': 'm4'});
        connection.push({'type': 'error', 'error': 'rate-limited'});
        async.flushMicrotasks();

        expect(errors, const [
          RelayError('too-large', 'm1'),
          RelayError('bad-payload', 'm2'),
          RelayError('bad-id', 'm3'),
          RelayError('queue-full', 'm4'),
          RelayError('rate-limited'),
        ]);
        expect(client.pendingIds, ['m4'], reason: 'queue-full 可以稍后重试，其余三种重发也不会成功');
        expect(client.state, SessionLinkState.connected);

        client.stop();
        async.flushMicrotasks();
      });
    });
  });

  group('接收', () {
    test('处理函数完成之后才 ack', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final gate = Completer<void>();
        final received = <IncomingRelayMessage>[];
        final client = _client(relay, onMessage: (m) {
          received.add(m);
          return gate.future;
        });
        final connection = _connect(async, relay, client);

        connection.push({'type': 'msg', 'id': 'r1', 'payload': 'cipher', 'ts': 1234});
        async.flushMicrotasks();
        expect(received, hasLength(1));
        expect(received.single.id, 'r1');
        expect(received.single.payload, 'cipher');
        expect(received.single.ts, 1234);
        expect(connection.sentOfType('ack'), isEmpty);

        gate.complete();
        async.flushMicrotasks();
        expect(connection.sentOfType('ack'), [
          {'type': 'ack', 'id': 'r1'},
        ]);

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('按到达顺序逐条处理，前一条没处理完不开始下一条', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final gates = {'r1': Completer<void>(), 'r2': Completer<void>()};
        final started = <String>[];
        final client = _client(relay, onMessage: (m) {
          started.add(m.id);
          return gates[m.id]!.future;
        });
        final connection = _connect(async, relay, client);

        connection.push({'type': 'msg', 'id': 'r1', 'payload': 'a', 'ts': 1});
        connection.push({'type': 'msg', 'id': 'r2', 'payload': 'b', 'ts': 2});
        async.flushMicrotasks();
        expect(started, ['r1']);

        gates['r1']!.complete();
        async.flushMicrotasks();
        expect(started, ['r1', 'r2']);
        gates['r2']!.complete();
        async.flushMicrotasks();
        expect(connection.sentOfType('ack').map((f) => f['id']), ['r1', 'r2']);

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('处理函数抛异常时不 ack，后续消息照常处理', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay, onMessage: (m) async {
          if (m.id == 'bad') throw StateError('cannot decrypt');
        });
        final connection = _connect(async, relay, client);

        connection.push({'type': 'msg', 'id': 'bad', 'payload': 'x', 'ts': 1});
        connection.push({'type': 'msg', 'id': 'good', 'payload': 'y', 'ts': 2});
        async.flushMicrotasks();

        expect(connection.sentOfType('ack').map((f) => f['id']), ['good']);
        expect(client.state, SessionLinkState.connected);

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('处理期间连接断开：不在旧连接上 ack，也不抛异常', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final gate = Completer<void>();
        final client = _client(relay, onMessage: (_) => gate.future);
        final first = _connect(async, relay, client);

        first.push({'type': 'msg', 'id': 'r1', 'payload': 'a', 'ts': 1});
        async.flushMicrotasks();
        first.drop();
        async.flushMicrotasks();
        gate.complete();
        async.flushMicrotasks();
        expect(first.sentOfType('ack'), isEmpty);

        async.elapse(const Duration(seconds: 1));
        relay.last.push(_welcome());
        async.flushMicrotasks();
        expect(relay.connections, hasLength(2));
        expect(client.state, SessionLinkState.connected);

        client.stop();
        async.flushMicrotasks();
      });
    });
    test('旧连接的消息还在处理时重连：新连接上收到的消息照常 ack', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final gate = Completer<void>();
        final client = _client(relay, onMessage: (m) {
          return m.id == 'slow' ? gate.future : Future<void>.value();
        });
        final first = _connect(async, relay, client);

        first.push({'type': 'msg', 'id': 'slow', 'payload': 'a', 'ts': 1});
        async.flushMicrotasks();
        first.drop();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        final second = relay.last;
        second.push(_welcome());
        second.push({'type': 'msg', 'id': 'next', 'payload': 'b', 'ts': 2});
        async.flushMicrotasks();
        expect(second.sentOfType('ack'), isEmpty);

        gate.complete();
        async.flushMicrotasks();
        expect(first.sentOfType('ack'), isEmpty);
        expect(second.sentOfType('ack').map((f) => f['id']), ['next']);

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('error 字段不是字符串的 error 帧被忽略', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        final errors = _collect(client.errors);
        final connection = _connect(async, relay, client);
        client.send('m1', 'one');

        connection.push({'type': 'error', 'error': 42, 'id': 'm1'});
        connection.push({'type': 'error', 'id': 'm1'});
        connection.push({'type': 'error', 'error': 'queue-full', 'id': 'm1'});
        async.flushMicrotasks();

        expect(errors, const [RelayError('queue-full', 'm1')]);
        expect(client.pendingIds, ['m1']);
        expect(client.state, SessionLinkState.connected);

        client.stop();
        async.flushMicrotasks();
      });
    });
  });

  group('重连', () {
    test('断开后按退避间隔重连，welcome 之后退避归零', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        final first = _connect(async, relay, client);

        first.drop();
        async.flushMicrotasks();
        expect(client.state, SessionLinkState.disconnected);
        relay.refuse = true;

        async.elapse(const Duration(milliseconds: 999));
        expect(relay.attempts, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(relay.attempts, hasLength(2), reason: '第 1 次失败后等 1 秒');

        async.elapse(const Duration(milliseconds: 1999));
        expect(relay.attempts, hasLength(2));
        async.elapse(const Duration(milliseconds: 1));
        expect(relay.attempts, hasLength(3), reason: '第 2 次失败后等 2 秒');

        async.elapse(const Duration(milliseconds: 4999));
        expect(relay.attempts, hasLength(3));
        async.elapse(const Duration(milliseconds: 1));
        expect(relay.attempts, hasLength(4), reason: '第 3 次失败后等 5 秒');

        async.elapse(const Duration(seconds: 5));
        expect(relay.attempts, hasLength(5), reason: '超出列表长度后一直用最后一项');
        expect(client.state, SessionLinkState.disconnected);

        relay.refuse = false;
        async.elapse(const Duration(seconds: 5));
        expect(relay.attempts, hasLength(6));
        expect(client.state, SessionLinkState.connecting);
        relay.last.push(_welcome());
        async.flushMicrotasks();
        expect(client.state, SessionLinkState.connected);

        relay.last.drop();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        expect(relay.attempts, hasLength(7), reason: 'welcome 之后退避从头开始');

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('被新连接替换（4001）后不再重连，并报告 replaced', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        final errors = _collect(client.errors);
        final connection = _connect(async, relay, client);

        connection.drop(4001);
        async.flushMicrotasks();
        expect(client.state, SessionLinkState.disconnected);
        expect(errors, const [RelayError('replaced')]);

        async.elapse(const Duration(minutes: 10));
        expect(relay.attempts, hasLength(1));
      });
    });

    test('已连接时定时发 ping，收到 pong 就保持连接', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(
          relay,
          pingInterval: const Duration(seconds: 25),
          pongTimeout: const Duration(seconds: 10),
        );
        final connection = _connect(async, relay, client);

        async.elapse(const Duration(seconds: 24));
        expect(connection.sentOfType('ping'), isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(connection.sentOfType('ping'), hasLength(1));
        connection.push({'type': 'pong'});
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 25));
        expect(connection.sentOfType('ping'), hasLength(2));
        connection.push({'type': 'pong'});
        async.flushMicrotasks();
        expect(client.state, SessionLinkState.connected);
        expect(connection.ended, isFalse);
        expect(relay.attempts, hasLength(1));

        client.stop();
        async.flushMicrotasks();
      });
    });

    test('ping 之后超时没收到 pong：关闭连接并重连', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(
          relay,
          pingInterval: const Duration(seconds: 25),
          pongTimeout: const Duration(seconds: 10),
        );
        final connection = _connect(async, relay, client);

        async.elapse(const Duration(seconds: 25));
        expect(connection.sentOfType('ping'), hasLength(1));
        async.elapse(const Duration(milliseconds: 9999));
        expect(connection.ended, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(connection.closedByClient, isTrue);
        expect(client.state, SessionLinkState.disconnected);

        async.elapse(const Duration(seconds: 1));
        expect(relay.attempts, hasLength(2));

        client.stop();
        async.flushMicrotasks();
      });
    });
  });

  group('停止', () {
    test('stop 关闭连接、不再重连、不留定时器，待确认的消息保留', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay, pingInterval: const Duration(seconds: 25));
        final connection = _connect(async, relay, client);
        client.send('m1', 'one');
        async.flushMicrotasks();

        client.stop();
        async.flushMicrotasks();
        expect(connection.closedByClient, isTrue);
        expect(client.state, SessionLinkState.disconnected);
        expect(client.peerOnline, isFalse);
        expect(client.pendingIds, ['m1']);
        expect(async.pendingTimers, isEmpty);

        async.elapse(const Duration(minutes: 10));
        expect(relay.attempts, hasLength(1));
      });
    });

    test('等待重连期间 stop 会取消重连', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        final connection = _connect(async, relay, client);
        connection.drop();
        async.flushMicrotasks();

        client.stop();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(minutes: 10));
        expect(relay.attempts, hasLength(1));
      });
    });

    test('连接尚未建立完成时 stop：建立后的连接被立即关闭', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        client.start();
        client.stop();
        async.flushMicrotasks();

        expect(client.state, SessionLinkState.disconnected);
        for (final connection in relay.connections) {
          expect(connection.closedByClient, isTrue);
        }
        async.elapse(const Duration(minutes: 10));
        expect(relay.attempts.length, lessThanOrEqualTo(1));
        expect(client.state, SessionLinkState.disconnected);
      });
    });

    test('stop 之后可以再次 start，并重发待确认的消息', () {
      fakeAsync((async) {
        final relay = FakeRelay();
        final client = _client(relay);
        _connect(async, relay, client);
        client.send('m1', 'one');
        async.flushMicrotasks();
        client.stop();
        async.flushMicrotasks();

        final second = _connect(async, relay, client);
        expect(relay.connections, hasLength(2));
        expect(client.state, SessionLinkState.connected);
        expect(second.sentOfType('msg'), [
          {'type': 'msg', 'id': 'm1', 'payload': 'one'},
        ]);

        client.stop();
        async.flushMicrotasks();
      });
    });
  });
}
