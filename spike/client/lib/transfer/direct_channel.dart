import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' hide Hmac;

/// Key bound to the DTLS fingerprints of this call. Argument order does not matter.
Uint8List directFileKey(String fingerprintA, String fingerprintB) {
  final sorted = [fingerprintA.trim().toLowerCase(), fingerprintB.trim().toLowerCase()]..sort();
  final material = utf8.encode('whisper-spike-direct-v1\n${sorted[0]}\n${sorted[1]}');
  return Uint8List.fromList(sha256.convert(material).bytes);
}

Uint8List _mac(Uint8List key, List<int> message) {
  return Uint8List.fromList(Hmac(sha256, key).convert(message).bytes);
}

bool _macEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// TCP file side channel. The handshake proves both ends know the DTLS
/// fingerprint key. The file itself is chunked AES-GCM.
class DirectLink {
  DirectLink._(this._socket, this._reader, this._key);

  final Socket _socket;
  final _ByteReader _reader;
  final Uint8List _key;
  final _algorithm = AesGcm.with256bits();

  static Future<DirectLink> connect({
    required String host,
    required int port,
    required Uint8List key,
    InternetAddress? sourceAddress,
  }) async {
    final socket = await Socket.connect(host, port, sourceAddress: sourceAddress, timeout: const Duration(seconds: 8));
    final link = DirectLink._(socket, _ByteReader(socket), key);
    await link._clientHandshake('$host:$port');
    return link;
  }

  static Future<DirectLink> accept({
    required Socket socket,
    required Uint8List key,
    required String boundAddress,
  }) async {
    final link = DirectLink._(socket, _ByteReader(socket), key);
    await link._serverHandshake(boundAddress);
    return link;
  }

  Future<void> sendFile({
    required String id,
    required String name,
    required List<Uint8List> payloads,
    required String sha256Hex,
    int chunkSize = 256 * 1024,
    void Function()? onProgress,
  }) async {
    final size = payloads.fold<int>(0, (sum, chunk) => sum + chunk.length);
    final header = utf8.encode(jsonEncode({'id': id, 'name': name, 'size': size, 'sha256': sha256Hex, 'chunkSize': chunkSize}));
    _socket.add(_u32(header.length));
    _socket.add(header);
    var sequence = 0;
    final pending = BytesBuilder(copy: false);
    for (final payload in payloads) {
      pending.add(payload);
      var buffered = pending.takeBytes();
      var offset = 0;
      while (buffered.length - offset >= chunkSize) {
        await _writeFrame(sequence, Uint8List.sublistView(buffered, offset, offset + chunkSize), id);
        sequence++;
        offset += chunkSize;
        onProgress?.call();
      }
      if (offset < buffered.length) {
        pending.add(Uint8List.sublistView(buffered, offset));
      }
    }
    final tail = pending.takeBytes();
    if (tail.isNotEmpty) {
      await _writeFrame(sequence, tail, id);
      onProgress?.call();
    }
    await _socket.flush();
  }

  Future<DirectReceive> receiveFile({void Function()? onProgress}) async {
    final headerLen = _readU32(await _reader.read(4));
    if (headerLen <= 0 || headerLen > 1024 * 1024) {
      throw StateError('直连文件头长度异常');
    }
    final header = jsonDecode(utf8.decode(await _reader.read(headerLen)));
    if (header is! Map) throw StateError('直连文件头不是对象');
    final id = header['id'];
    final name = header['name'];
    final size = header['size'];
    final sha = header['sha256'];
    final chunkSize = header['chunkSize'];
    if (id is! String || name is! String || size is! int || sha is! String || chunkSize is! int || chunkSize <= 0) {
      throw StateError('直连文件头缺少字段');
    }
    final clock = Stopwatch()..start();
    final plain = BytesBuilder(copy: false);
    var got = 0;
    var sequence = 0;
    while (got < size) {
      final seq = _readU32(await _reader.read(4));
      final cipherLen = _readU32(await _reader.read(4));
      if (seq != sequence || cipherLen <= 16 || cipherLen > chunkSize + 16 + 64) {
        throw StateError('直连分块序号或长度不对');
      }
      final cipher = await _reader.read(cipherLen);
      final clear = await _decrypt(sequence, cipher, id);
      plain.add(clear);
      got += clear.length;
      sequence++;
      onProgress?.call();
    }
    clock.stop();
    final bytes = plain.takeBytes();
    final digest = sha256.convert(bytes).toString();
    return DirectReceive(
      id: id,
      name: name,
      bytes: bytes,
      sha256Hex: digest,
      ok: digest == sha && bytes.length == size,
      millis: clock.elapsedMilliseconds,
    );
  }

  Future<void> close() async {
    await _socket.close();
  }

  Future<void> _clientHandshake(String boundAddress) async {
    final nonce = _random(16);
    _socket.add(nonce);
    _socket.add(_mac(_key, [...utf8.encode('client\n$boundAddress\n'), ...nonce]));
    await _socket.flush();
    final serverNonce = await _reader.read(16);
    final serverMac = await _reader.read(32);
    final expected = _mac(_key, [...utf8.encode('server\n$boundAddress\n'), ...nonce, ...serverNonce]);
    if (!_macEquals(serverMac, expected)) {
      await _socket.close();
      throw StateError('直连握手校验失败');
    }
  }

  Future<void> _serverHandshake(String boundAddress) async {
    final clientNonce = await _reader.read(16);
    final clientMac = await _reader.read(32);
    final expected = _mac(_key, [...utf8.encode('client\n$boundAddress\n'), ...clientNonce]);
    if (!_macEquals(clientMac, expected)) {
      await _socket.close();
      throw StateError('直连握手校验失败');
    }
    final nonce = _random(16);
    _socket.add(nonce);
    _socket.add(_mac(_key, [...utf8.encode('server\n$boundAddress\n'), ...clientNonce, ...nonce]));
    await _socket.flush();
  }

  Future<void> _writeFrame(int sequence, Uint8List plain, String id) async {
    final box = await _algorithm.encrypt(
      plain,
      secretKey: SecretKey(_key),
      nonce: _nonce(sequence),
      aad: utf8.encode('$id:$sequence'),
    );
    final body = Uint8List(box.cipherText.length + box.mac.bytes.length);
    body.setRange(0, box.cipherText.length, box.cipherText);
    body.setRange(box.cipherText.length, body.length, box.mac.bytes);
    _socket.add(_u32(sequence));
    _socket.add(_u32(body.length));
    _socket.add(body);
  }

  Future<List<int>> _decrypt(int sequence, Uint8List body, String id) {
    if (body.length < 16) throw StateError('直连密文太短');
    final macStart = body.length - 16;
    return _algorithm.decrypt(
      SecretBox(Uint8List.sublistView(body, 0, macStart), nonce: _nonce(sequence), mac: Mac(Uint8List.sublistView(body, macStart))),
      secretKey: SecretKey(_key),
      aad: utf8.encode('$id:$sequence'),
    );
  }

  List<int> _nonce(int sequence) {
    final nonce = Uint8List(12);
    nonce[8] = (sequence >> 24) & 0xff;
    nonce[9] = (sequence >> 16) & 0xff;
    nonce[10] = (sequence >> 8) & 0xff;
    nonce[11] = sequence & 0xff;
    return nonce;
  }

  Uint8List _random(int length) {
    final bytes = Uint8List(length);
    final random = Random.secure();
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }
}

class DirectReceive {
  const DirectReceive({
    required this.id,
    required this.name,
    required this.bytes,
    required this.sha256Hex,
    required this.ok,
    required this.millis,
  });

  final String id;
  final String name;
  final Uint8List bytes;
  final String sha256Hex;
  final bool ok;
  final int millis;
}

class _ByteReader {
  _ByteReader(Socket socket) : _iterator = StreamIterator(socket);

  final StreamIterator<Uint8List> _iterator;
  Uint8List _pending = Uint8List(0);
  var _offset = 0;

  Future<Uint8List> read(int length) async {
    final out = Uint8List(length);
    var filled = 0;
    while (filled < length) {
      if (_offset >= _pending.length) {
        final more = await _iterator.moveNext();
        if (!more) throw StateError('直连连接提前关闭');
        _pending = _iterator.current;
        _offset = 0;
        if (_pending.isEmpty) continue;
      }
      final take = length - filled < _pending.length - _offset ? length - filled : _pending.length - _offset;
      out.setRange(filled, filled + take, _pending, _offset);
      _offset += take;
      filled += take;
    }
    return out;
  }
}

Uint8List _u32(int value) {
  return Uint8List(4)
    ..[0] = (value >> 24) & 0xff
    ..[1] = (value >> 16) & 0xff
    ..[2] = (value >> 8) & 0xff
    ..[3] = value & 0xff;
}

int _readU32(Uint8List bytes) {
  return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
}
