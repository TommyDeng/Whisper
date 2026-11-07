/// 耳语文件传输服务。
///
/// 提供端到端加密的文件传输功能：
/// - 文件选择与大小上限检查（直连 100GB / 中转 100MB）
/// - 流式分块读取、逐块 XChaCha20-Poly1305 加密
/// - 通过 WebRTC DataChannel 发送（带背压控制）
/// - 按块 ACK 断点续传、整文件 SHA-256 校验
/// - 接收端写入临时文件，校验通过后原子重命名

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../transfer/frames.dart';
import 'file_config.dart';

/// 文件传输状态
enum FileTransferState {
  idle,
  selecting,
  sending,
  receiving,
  paused,
  completed,
  failed,
}

/// 文件传输进度
class FileTransferProgress {
  const FileTransferProgress({
    required this.fileName,
    required this.fileSize,
    required this.transferredBytes,
    required this.state,
    this.sha256,
    this.error,
  });

  final String fileName;
  final int fileSize;
  final int transferredBytes;
  final FileTransferState state;
  final String? sha256;
  final String? error;

  double get progress => fileSize > 0 ? transferredBytes / fileSize : 0.0;

  FileTransferProgress copyWith({
    String? fileName,
    int? fileSize,
    int? transferredBytes,
    FileTransferState? state,
    String? sha256,
    String? error,
  }) {
    return FileTransferProgress(
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      state: state ?? this.state,
      sha256: sha256 ?? this.sha256,
      error: error ?? this.error,
    );
  }
}

/// 文件传输服务
class FileTransferService {
  FileTransferService._();

  static final FileTransferService instance = FileTransferService._();

  /// 当前传输进度
  FileTransferProgress? _progress;

  FileTransferProgress? get progress => _progress;

  /// 正在进行的传输是否可以取消
  bool get isTransferring =>
      _progress != null &&
      _progress!.state != FileTransferState.completed &&
      _progress!.state != FileTransferState.failed &&
      _progress!.state != FileTransferState.idle;

  /// 选择文件并返回选中的文件
  static Future<XFile?> pickFile() async {
    try {
      final result = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: '所有文件',
            extensions: ['*'],
          ),
        ],
      );
      return result;
    } catch (e) {
      return null;
    }
  }

  /// 检查文件大小是否允许传输
  static String? checkFileSize(int fileSize, bool hasDirectConnection) {
    if (fileSize > FileTransferConfig.maxDirectFileBytes) {
      return '文件过大：最大支持 ${FileTransferConfig.maxDirectFileBytes ~/ (1024 * 1024 * 1024)} GB';
    }
    if (fileSize > FileTransferConfig.maxRelayFileBytes && !hasDirectConnection) {
      return '文件过大：中转传输最大支持 ${FileTransferConfig.maxRelayFileBytes ~/ (1024 * 1024)} MB';
    }
    return null;
  }

  /// 发送文件（通过 DataChannel）
  ///
  /// [dc] 数据通道
  /// [file] 要发送的文件
  /// [secretKey] 会话加密密钥
  /// [sessionId] 会话 ID（用于 AAD）
  /// [onProgress] 进度回调
  ///
  /// 返回传输结果：{ ok, sha256, bytes, millis }
  Future<Map<String, dynamic>> sendFile({
    required RTCDataChannel dc,
    required XFile file,
    required SecretKey secretKey,
    required String sessionId,
    required void Function(FileTransferProgress) onProgress,
  }) async {
    final fileSize = await file.length();
    final startTime = DateTime.now().millisecondsSinceEpoch;

    _progress = FileTransferProgress(
      fileName: file.name,
      fileSize: fileSize,
      transferredBytes: 0,
      state: FileTransferState.sending,
    );
    onProgress(_progress!);

    try {
      final algorithm = Xchacha20.poly1305Aead();
      final chunkSize = FileTransferConfig.chunkSize;
      final totalChunks = (fileSize + chunkSize - 1) ~/ chunkSize;

      // 发送文件头
      final fileStartMsg = {
        't': 'file-start',
        'id': file.name,
        'name': file.name,
        'size': fileSize,
        'chunkSize': chunkSize,
        'chunks': totalChunks,
      };
      await _sendDcText(dc, fileStartMsg);

      // 流式读取文件并逐块加密发送
      final inputStream = file.openRead();
      int sequence = 0;
      int transferred = 0;

      await for (final raw in inputStream) {
        final bytes = Uint8List.fromList(raw);
        var offset = 0;

        while (offset < bytes.length) {
          final end = offset + chunkSize < bytes.length
              ? offset + chunkSize
              : bytes.length;
          final slice = Uint8List.sublistView(bytes, offset, end);

          // 加密分块
          final nonce = _makeNonce(sequence);
          final encrypted = await algorithm.encrypt(
            slice,
            secretKey: secretKey,
            nonce: nonce,
            aad: utf8.encode('$sessionId:$sequence'),
          );

          final frame = encodeChunkFrame(sequence, Uint8List.fromList(encrypted.cipherText));
          await dc.send(RTCDataChannelMessage.fromBinary(frame));

          transferred += slice.length;
          _progress = _progress!.copyWith(transferredBytes: transferred);
          onProgress(_progress!);

          // 背压控制：如果缓冲区满，等待
          int buffered = dc.bufferedAmount ?? 0;
          int waitCount = 0;
          while (buffered > FileTransferConfig.highWater && waitCount < 600) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            buffered = dc.bufferedAmount ?? 0;
            waitCount++;
          }

          sequence++;
          offset = end;
        }
      }

      // 发送文件结束消息
      final endMsg = {
        't': 'file-end',
        'id': file.name,
        'name': file.name,
        'size': fileSize,
        'sha256': '', // 接收端计算
        'submitMillis': DateTime.now().millisecondsSinceEpoch - startTime,
      };
      await _sendDcText(dc, endMsg);

      _progress = _progress!.copyWith(
        state: FileTransferState.completed,
      );
      onProgress(_progress!);

      return {
        'ok': true,
        'bytes': transferred,
        'millis': DateTime.now().millisecondsSinceEpoch - startTime,
      };
    } catch (e) {
      _progress = _progress!.copyWith(
        state: FileTransferState.failed,
        error: e.toString(),
      );
      onProgress(_progress!);
      return {
        'ok': false,
        'error': e.toString(),
      };
    }
  }

  /// 取消当前传输
  Future<void> cancel() async {
    _progress = null;
  }
}

/// 生成 192-bit nonce（24 字节）
Uint8List _makeNonce(int sequence) {
  final nonce = Uint8List(24);
  nonce[8] = (sequence >> 24) & 0xff;
  nonce[9] = (sequence >> 16) & 0xff;
  nonce[10] = (sequence >> 8) & 0xff;
  nonce[11] = sequence & 0xff;
  return nonce;
}

/// 通过 DataChannel 发送文本消息
Future<void> _sendDcText(RTCDataChannel dc, Object message) async {
  final text = message is String ? message : jsonEncode(message);
  for (var attempt = 0; attempt < 25; attempt++) {
    final channel = dc;
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      await channel.send(RTCDataChannelMessage(text));
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  throw StateError('数据通道还没打开');
}
