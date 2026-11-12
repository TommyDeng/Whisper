import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../contact/contact.dart';
import '../messaging/message_codec.dart';
import '../messaging/messaging_service.dart';
import '../storage/local_db.dart';
import 'file_relay_transfer.dart';

// 把“传文件”和“发文件消息”串起来，供界面使用。见 docs/file-relay.md 的“本地记录”。

/// 一次进行中（或刚失败）的上传或下载。
class FileTransferState {
  FileTransferState._({
    required this.id,
    required this.sessionId,
    required this.name,
    required this.total,
    required this.isUpload,
  });

  /// 上传：本地生成的临时 ID；下载：文件消息的 ID。
  final String id;
  final String sessionId;
  final String name;
  final bool isUpload;

  /// 明文字节数。
  final int total;
  int _done = 0;
  String? _error;
  final CancelToken _cancel = CancelToken();

  int get done => _done;

  /// 失败原因（[FileTransferException.code]，或 `failed`）；进行中为 null。
  String? get error => _error;

  bool get failed => _error != null;
}

class FileShareService {
  FileShareService({required this.messaging, required this.transfer});

  final MessagingService messaging;
  final FileRelayTransfer transfer;

  final Map<String, FileTransferState> _uploads = {};
  final Map<String, FileTransferState> _downloads = {}; // 以消息 ID 为键
  final _updates = StreamController<String>.broadcast();

  /// 某个会话的传输有变化（开始、进度、结束）时发出它的 sessionId。
  Stream<String> get updates => _updates.stream;

  /// 一个会话里进行中和失败的上传，按开始的先后。
  List<FileTransferState> uploads(String sessionId) => [
        for (final state in _uploads.values)
          if (state.sessionId == sessionId) state,
      ];

  /// 一条文件消息的下载状态；没在下载（也没有失败记录）时为 null。
  FileTransferState? downloadState(String msgId) => _downloads[msgId];

  /// 一个会话里各条文件消息对应的本地文件：发出的是源文件，收到的是保存位置。
  Future<Map<String, String>> localPaths(String sessionId) =>
      LocalDatabase.getFilePaths(sessionId);

  /// 把 [file] 传到中继并给 [contact] 发一条文件消息。
  /// 成功返回消息 ID；失败（原因在 [uploads] 的状态里）或被取消返回 null。
  Future<String?> send(Contact contact, File file) async {
    final sessionId = contact.sessionId;
    final state = FileTransferState._(
      id: MessageCodec.newMessageId(),
      sessionId: sessionId,
      name: p.basename(file.path),
      total: await _lengthOrZero(file),
      isUpload: true,
    );
    _uploads[state.id] = state;
    _notify(sessionId);
    try {
      final offer = await transfer.upload(
        file,
        cancel: state._cancel,
        onProgress: (done, _) => _progress(state, done),
      );
      final String msgId;
      try {
        msgId = await messaging.sendFile(contact, offer);
      } catch (_) {
        await transfer.discard(offer.fileId); // 消息没发出去，对方永远不会来取
        rethrow;
      }
      await LocalDatabase.setFilePath(msgId, file.absolute.path);
      _uploads.remove(state.id);
      _notify(sessionId);
      return msgId;
    } on TransferCancelled {
      _uploads.remove(state.id);
    } on FileTransferException catch (error) {
      state._error = error.code;
    } catch (_) {
      state._error = 'failed';
    }
    _notify(sessionId);
    return null;
  }

  /// 把文件消息 [message] 的文件下载到 [target]（之前中断过就续传）。
  /// 成功返回保存的文件；失败（原因在 [downloadState] 里）或被取消返回 null。
  Future<File?> download(Contact contact, ChatMessage message, File target) async {
    final offer = message.file;
    if (offer == null) throw ArgumentError('不是文件消息');
    final running = _downloads[message.id];
    if (running != null && !running.failed) throw StateError('这个文件正在下载');

    final sessionId = contact.sessionId;
    final state = FileTransferState._(
      id: message.id,
      sessionId: sessionId,
      name: offer.safeName,
      total: offer.size,
      isUpload: false,
    );
    _downloads[state.id] = state;
    _notify(sessionId);
    try {
      final saved = await transfer.download(
        offer,
        target,
        cancel: state._cancel,
        onProgress: (done, _) => _progress(state, done),
      );
      await LocalDatabase.setFilePath(message.id, saved.absolute.path);
      _remove(state);
      _notify(sessionId);
      return saved;
    } on TransferCancelled {
      _remove(state);
    } on FileTransferException catch (error) {
      state._error = error.code;
    } catch (_) {
      state._error = 'failed';
    }
    _notify(sessionId);
    return null;
  }

  /// 取消一次进行中的传输，或清掉一条失败记录。[id] 是 [FileTransferState.id]。
  void cancel(String id) {
    final state = _uploads[id] ?? _downloads[id];
    if (state == null) return;
    state._cancel.cancel();
    if (state.failed) {
      _remove(state);
      _notify(state.sessionId);
    }
  }

  /// 取消一个会话的全部传输（删除联系人时调用）。
  void cancelSession(String sessionId) {
    for (final state in [..._uploads.values, ..._downloads.values]) {
      if (state.sessionId == sessionId) _drop(state);
    }
    _notify(sessionId);
  }

  /// 取消全部传输（清空全部数据时调用）。
  void reset() {
    final all = [..._uploads.values, ..._downloads.values];
    all.forEach(_drop);
    for (final sessionId in {for (final state in all) state.sessionId}) {
      _notify(sessionId);
    }
  }

  Future<void> dispose() async {
    reset();
    await _updates.close();
  }

  // ---------------------------------------------------------------------------

  void _drop(FileTransferState state) {
    state._cancel.cancel();
    _remove(state);
  }

  /// 只移除自己：同一条消息重新下载时，旧的那次不能把新的状态删掉。
  void _remove(FileTransferState state) {
    final map = state.isUpload ? _uploads : _downloads;
    if (identical(map[state.id], state)) map.remove(state.id);
  }

  void _progress(FileTransferState state, int done) {
    state._done = done;
    _notify(state.sessionId);
  }

  void _notify(String sessionId) {
    if (!_updates.isClosed) _updates.add(sessionId);
  }

  static Future<int> _lengthOrZero(File file) async {
    try {
      return await file.length();
    } on FileSystemException {
      return 0;
    }
  }
}
