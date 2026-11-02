import 'dart:convert';

sealed class SpikeMessage {
  const SpikeMessage();
}

class TextSpike extends SpikeMessage {
  const TextSpike(this.body);

  final String body;
}

class FileStartSpike extends SpikeMessage {
  const FileStartSpike({required this.id, required this.name, required this.size});

  final String id;
  final String name;
  final int size;
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

String encodeFileStart({required String id, required String name, required int size}) {
  return jsonEncode({'t': 'file-start', 'id': id, 'name': name, 'size': size});
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
    case 'file-start':
      final id = decoded['id'];
      final name = decoded['name'];
      final size = decoded['size'];
      if (id is! String || name is! String || size is! int || size < 0) return UnknownSpike(raw);
      return FileStartSpike(id: id, name: name, size: size);
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
