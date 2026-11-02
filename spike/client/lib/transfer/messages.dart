import 'dart:convert';

sealed class SpikeMessage {
  const SpikeMessage();
}

class TextSpike extends SpikeMessage {
  const TextSpike(this.body);

  final String body;
}

class TextAckSpike extends SpikeMessage {
  const TextAckSpike(this.body);

  final String body;
}

class FileStartSpike extends SpikeMessage {
  const FileStartSpike({
    required this.id,
    required this.name,
    required this.size,
    required this.chunkSize,
    required this.chunks,
  });

  final String id;
  final String name;
  final int size;
  final int chunkSize;
  final int chunks;
}

class FileStartAckSpike extends SpikeMessage {
  const FileStartAckSpike(this.id);

  final String id;
}

class FileNakSpike extends SpikeMessage {
  const FileNakSpike(this.id, this.missing);

  final String id;
  final List<int> missing;
}

class FileEndSpike extends SpikeMessage {
  const FileEndSpike({required this.id, required this.sha256, required this.submitMillis});

  final String id;
  final String sha256;
  final int submitMillis;
}

class FileResultSpike extends SpikeMessage {
  const FileResultSpike({
    required this.id,
    required this.ok,
    required this.bytes,
    required this.millis,
    required this.sha256,
  });

  final String id;
  final bool ok;
  final int bytes;
  final int millis;
  final String sha256;
}

class UnknownSpike extends SpikeMessage {
  const UnknownSpike(this.raw);

  final String raw;
}

String encodeText(String body) => jsonEncode({'t': 'text', 'body': body});

String encodeTextAck(String body) => jsonEncode({'t': 'text-ack', 'body': body});

String encodeFileStart({
  required String id,
  required String name,
  required int size,
  required int chunkSize,
  required int chunks,
}) {
  return jsonEncode({
    't': 'file-start',
    'id': id,
    'name': name,
    'size': size,
    'chunkSize': chunkSize,
    'chunks': chunks,
  });
}

String encodeFileStartAck(String id) => jsonEncode({'t': 'file-start-ack', 'id': id});

String encodeFileNak({required String id, required List<int> missing}) {
  return jsonEncode({'t': 'file-nak', 'id': id, 'missing': missing});
}

String encodeFileEnd({required String id, required String sha256, required int submitMillis}) {
  return jsonEncode({'t': 'file-end', 'id': id, 'sha256': sha256, 'submitMillis': submitMillis});
}

String encodeFileResult({
  required String id,
  required bool ok,
  required int bytes,
  required int millis,
  required String sha256,
}) {
  return jsonEncode({
    't': 'file-result',
    'id': id,
    'ok': ok,
    'bytes': bytes,
    'millis': millis,
    'sha256': sha256,
  });
}

SpikeMessage parseSpikeMessage(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return UnknownSpike(raw);
  }
  if (decoded is! Map) return UnknownSpike(raw);
  switch (decoded['t']) {
    case 'text':
      final body = decoded['body'];
      if (body is! String) return UnknownSpike(raw);
      return TextSpike(body);
    case 'text-ack':
      final body = decoded['body'];
      if (body is! String) return UnknownSpike(raw);
      return TextAckSpike(body);
    case 'file-start':
      final id = decoded['id'];
      final name = decoded['name'];
      final size = decoded['size'];
      final chunkSize = decoded['chunkSize'];
      final chunks = decoded['chunks'];
      if (id is! String ||
          name is! String ||
          size is! int ||
          size < 0 ||
          chunkSize is! int ||
          chunkSize <= 0 ||
          chunks is! int ||
          chunks < 0) {
        return UnknownSpike(raw);
      }
      return FileStartSpike(id: id, name: name, size: size, chunkSize: chunkSize, chunks: chunks);
    case 'file-start-ack':
      final id = decoded['id'];
      if (id is! String) return UnknownSpike(raw);
      return FileStartAckSpike(id);
    case 'file-nak':
      final id = decoded['id'];
      final missing = decoded['missing'];
      if (id is! String || missing is! List) return UnknownSpike(raw);
      final sequences = <int>[];
      for (final item in missing) {
        if (item is! int || item < 0) return UnknownSpike(raw);
        sequences.add(item);
      }
      return FileNakSpike(id, sequences);
    case 'file-end':
      final id = decoded['id'];
      final sha = decoded['sha256'];
      final submit = decoded['submitMillis'];
      if (id is! String || sha is! String || submit is! int) return UnknownSpike(raw);
      return FileEndSpike(id: id, sha256: sha, submitMillis: submit);
    case 'file-result':
      final id = decoded['id'];
      final ok = decoded['ok'];
      final bytes = decoded['bytes'];
      final millis = decoded['millis'];
      final sha = decoded['sha256'];
      if (id is! String || ok is! bool || bytes is! int || millis is! int || sha is! String) {
        return UnknownSpike(raw);
      }
      return FileResultSpike(id: id, ok: ok, bytes: bytes, millis: millis, sha256: sha);
    default:
      return UnknownSpike(raw);
  }
}

String safeFileName(String name) {
  final base = name.split(RegExp(r'[\\/]')).last.trim();
  final cleaned = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'received.bin';
  return cleaned;
}
