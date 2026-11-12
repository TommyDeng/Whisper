import 'dart:async';

import 'package:whisper/contact/contact.dart';
import 'package:whisper/files/file_direct_service.dart';
import 'package:whisper/files/file_direct_signal.dart';

class PipeHub {
  PipeHub({required this.aliceView, required this.bobView}) {
    alice = PipeTransport(this, isAlice: true);
    bob = PipeTransport(this, isAlice: false);
  }

  final Contact aliceView;
  final Contact bobView;
  late final PipeTransport alice;
  late final PipeTransport bob;
  bool aliceOnline = true;
  bool bobOnline = true;
}

class PipeTransport implements FileDirectTransport {
  PipeTransport(this.hub, {required this.isAlice});

  final PipeHub hub;
  final bool isAlice;
  bool connected = true;
  final sent = <FileDirectSignal>[];
  final _incoming = StreamController<IncomingFileSignal>.broadcast();
  final _dropped =
      StreamController<({String sessionId, String id})>.broadcast();
  int _n = 0;

  PipeTransport get _peer => isAlice ? hub.bob : hub.alice;

  bool get _peerOnline => isAlice ? hub.bobOnline : hub.aliceOnline;

  Contact get _selfAsSeenByPeer => isAlice ? hub.bobView : hub.aliceView;

  @override
  Future<String?> send(Contact contact, String body) async {
    if (!connected) return null;
    final id = 'm${_n++}';
    final signal = FileDirectSignal.decode(body);
    if (signal != null) sent.add(signal);
    if (!_peerOnline) {
      scheduleMicrotask(
        () => _dropped.add((sessionId: contact.sessionId, id: id)),
      );
      return id;
    }
    scheduleMicrotask(
      () => _peer._incoming.add(IncomingFileSignal(_selfAsSeenByPeer, body)),
    );
    return id;
  }

  @override
  Stream<IncomingFileSignal> get incoming => _incoming.stream;

  @override
  Stream<({String sessionId, String id})> get dropped => _dropped.stream;
}
