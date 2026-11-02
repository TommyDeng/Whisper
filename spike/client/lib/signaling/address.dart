import 'dart:math';

const roomAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

final roomCodePattern = RegExp(r'^[A-Za-z0-9_-]{4,32}$');

String generateRoomCode(Random random) {
  return List.generate(6, (_) => roomAlphabet[random.nextInt(roomAlphabet.length)]).join();
}

String buildSignalingUrl(String base, String room) {
  final trimmedRoom = room.trim();
  if (!roomCodePattern.hasMatch(trimmedRoom)) {
    throw const FormatException('房间码需要 4–32 位字母、数字、下划线或连字符');
  }
  final text = base.trim();
  if (text.isEmpty) {
    throw const FormatException('请填写信令地址');
  }
  final uri = Uri.parse(text);
  if (uri.scheme != 'ws' && uri.scheme != 'wss') {
    throw const FormatException('信令地址需要 ws:// 或 wss://');
  }
  final encoded = Uri.encodeComponent(trimmedRoom);
  final path = uri.path;
  final String nextPath;
  if (path.isEmpty || path == '/') {
    nextPath = '/ws/$encoded';
  } else if (path.endsWith('/ws')) {
    nextPath = '$path/$encoded';
  } else if (path.endsWith('/ws/')) {
    nextPath = '$path$encoded';
  } else {
    final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    nextPath = '$trimmed/ws/$encoded';
  }
  return _withPath(uri, nextPath);
}

String healthUrlFor(String base) {
  final uri = Uri.parse(base.trim());
  final scheme = uri.scheme == 'wss' ? 'https' : 'http';
  var path = uri.path;
  if (path.endsWith('/ws')) {
    path = path.substring(0, path.length - 3);
  } else if (path.endsWith('/ws/')) {
    path = path.substring(0, path.length - 4);
  }
  if (path.isEmpty || path == '/') {
    path = '/health';
  } else {
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    path = '$path/health';
  }
  return _withPath(uri.replace(scheme: scheme), path);
}

String _withPath(Uri uri, String path) {
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path,
  ).toString();
}
