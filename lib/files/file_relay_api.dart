import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'file_cipher.dart';

// 中继文件接口（PUT/GET /file/<fileId>/<index>、DELETE /file/<fileId>）的客户端。
// 接口约定见 docs/file-relay.md。这里不记录路径、文件 ID 或内容。

/// 会话凭据：与连接 `/session/<sessionId>?peer=a|b` 是同一套身份。
/// [toString] 不含凭据内容。
class FileRelayAuth {
  const FileRelayAuth({required this.sessionId, required this.peer});

  final String sessionId;

  /// `a`（邀请人）或 `b`（加入者）。
  final String peer;

  String get headerValue => 'Whisper $sessionId $peer';

  @override
  String toString() => 'FileRelayAuth';
}

/// 中继拒绝了请求（[status] 是 HTTP 状态码，[code] 是响应里的 error），
/// 或者没连上（[status] 为 0，[code] 为 `network`）。
class FileRelayException implements Exception {
  const FileRelayException(this.status, this.code);

  final int status;
  final String code;

  bool get isNetwork => status == 0;

  /// 值得重试：没连上、被限流或中继自己出错。
  bool get isTransient => status == 0 || status == 429 || status >= 500;

  @override
  String toString() => 'FileRelayException($status, $code)';
}

abstract class FileRelayApi {
  /// 上传一个密文块。这一块已经在中继上时也算成功。
  Future<void> putChunk(String fileId, int index, Uint8List sealed, FileRelayAuth auth);

  /// 下载一个密文块。不存在（过期或已删除）时抛 status 为 404 的 [FileRelayException]。
  Future<Uint8List> getChunk(String fileId, int index, FileRelayAuth auth);

  /// 删除一个文件的所有块。
  Future<void> deleteFile(String fileId, FileRelayAuth auth);
}

class HttpFileRelay implements FileRelayApi {
  /// [relayUri] 是中继地址，`ws`/`wss` 会换成 `http`/`https`。
  HttpFileRelay(Uri relayUri, {this.timeout = const Duration(seconds: 30)})
      : _base = _httpBase(relayUri);

  static const int maxSealedBytes = FileCipher.chunkSize + FileCipher.tagLength;

  final Uri _base;
  HttpClient? _client; // 各块共用一条连接，省掉每块一次握手

  /// 一次请求每个阶段（连接、发送、接收）的超时。
  final Duration timeout;

  static Uri _httpBase(Uri uri) {
    final scheme = switch (uri.scheme) {
      'wss' || 'https' => 'https',
      'ws' || 'http' => 'http',
      _ => throw ArgumentError.value(uri.scheme, 'relayUri', '不支持的协议'),
    };
    return uri.replace(scheme: scheme, path: '/', query: null, fragment: null);
  }

  Uri _chunk(String fileId, int index) => _base.resolve('/file/$fileId/$index');

  @override
  Future<void> putChunk(String fileId, int index, Uint8List sealed, FileRelayAuth auth) =>
      _request('PUT', _chunk(fileId, index), auth, body: sealed, (response) async {
        final status = response.statusCode;
        final code = await _errorCode(response);
        if (status == 201 || (status == 409 && code == 'chunk-exists')) return;
        throw FileRelayException(status, code);
      });

  @override
  Future<Uint8List> getChunk(String fileId, int index, FileRelayAuth auth) =>
      _request('GET', _chunk(fileId, index), auth, (response) async {
        if (response.statusCode != 200) {
          throw FileRelayException(response.statusCode, await _errorCode(response));
        }
        if (response.contentLength > maxSealedBytes) {
          throw const FileRelayException(200, 'too-large');
        }
        final builder = BytesBuilder(copy: false);
        await for (final part in response.timeout(timeout)) {
          if (builder.length + part.length > maxSealedBytes) {
            throw const FileRelayException(200, 'too-large');
          }
          builder.add(part);
        }
        return builder.takeBytes();
      });

  @override
  Future<void> deleteFile(String fileId, FileRelayAuth auth) =>
      _request('DELETE', _base.resolve('/file/$fileId'), auth, (response) async {
        final status = response.statusCode;
        final code = await _errorCode(response);
        if (status != 200) throw FileRelayException(status, code);
      });

  Future<T> _request<T>(
    String method,
    Uri uri,
    FileRelayAuth auth,
    Future<T> Function(HttpClientResponse response) handle, {
    Uint8List? body,
  }) async {
    final client = _client ??= (HttpClient()..connectionTimeout = timeout);
    try {
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.headers.set('authorization', auth.headerValue);
      if (body != null) {
        request.headers.contentType = ContentType.binary;
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(timeout);
      return await handle(response);
    } on FileRelayException {
      rethrow;
    } on IOException {
      _drop(client);
      throw const FileRelayException(0, 'network');
    } on TimeoutException {
      _drop(client);
      throw const FileRelayException(0, 'network');
    }
  }

  /// 连接可能卡住了：强制关掉，下次请求重新连。
  void _drop(HttpClient client) {
    client.close(force: true);
    if (identical(_client, client)) _client = null;
  }

  /// 关掉空闲连接。之后还可以继续用（会重新连接）。
  void close() {
    _client?.close(force: true);
    _client = null;
  }

  /// 读出错误响应里的 error 字段；读不出来时返回空串。最多读 4 KiB。
  Future<String> _errorCode(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final part in response.timeout(timeout)) {
      if (builder.length + part.length > 4096) return '';
      builder.add(part);
    }
    try {
      final json = jsonDecode(utf8.decode(builder.takeBytes()));
      final error = json is Map<String, dynamic> ? json['error'] : null;
      return error is String ? error : '';
    } catch (_) {
      return '';
    }
  }
}
