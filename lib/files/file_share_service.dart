import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../contact/contact.dart';
import '../messaging/message_codec.dart';
import '../messaging/messaging_service.dart';
import '../storage/local_db.dart';
import 'file_cipher.dart';
import 'file_offer.dart';
import 'file_direct_service.dart';
import 'file_relay_api.dart';
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
    this.isDirect = false,
    this.needsAccept = false,
  });

  /// 上传：本地生成的临时 ID；下载或来传：文件消息 ID / 直传 xferId。
  final String id;
  final String sessionId;
  final String name;
  final bool isUpload;

  /// 是否走点对点直传（而不是 R2 中转）。
  final bool isDirect;

  /// 来传还在等用户选保存位置。
  final bool needsAccept;

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
  FileShareService({
    required this.messaging,
    required this.transfer,
    this.direct,
  }) {
    if (direct != null) {
      _subs.add(direct!.updates.listen(_onDirectUpdate));
      _subs.add(messaging.updates.listen(_bindPendingPaths));
    }
  }

  final MessagingService messaging;
  final FileRelayTransfer transfer;

  /// 点对点直传；双方在线时优先走这里。为 null 时只能在用户确认后走中转。
  final FileDirectService? direct;

  final Map<String, FileTransferState> _uploads = {};
  final Map<String, FileTransferState> _downloads = {}; // 以消息 ID 为键
  final _updates = StreamController<String>.broadcast();
  final _incomingArrivals = StreamController<String>.broadcast();
  final _announcedIncoming = <String, Set<String>>{}; // sessionId → 已提示过的来传 id
  final _subs = <StreamSubscription<dynamic>>[];

  /// 某个会话的传输有变化（开始、进度、结束）时发出它的 sessionId。
  Stream<String> get updates => _updates.stream;

  /// 新的直传来传出现（尚待用户接受）时发出它的 sessionId，每个 id 只发一次。
  Stream<String> get incomingArrivals => _incomingArrivals.stream;

  /// 一个会话里进行中和失败的上传，按开始的先后。
  List<FileTransferState> uploads(String sessionId) => [
    for (final state in _uploads.values)
      if (state.sessionId == sessionId) state,
  ];

  /// 一条文件消息的下载状态；没在下载（也没有失败记录）时为 null。
  FileTransferState? downloadState(String msgId) => _downloads[msgId];

  /// 一个会话里待接受、进行中或刚失败的大文件来传。
  List<FileTransferState> incoming(String sessionId) => [
    for (final item
        in direct?.incoming(sessionId) ?? const <FileDirectIncoming>[])
      FileTransferState._(
          id: item.id,
          sessionId: item.sessionId,
          name: item.name,
          total: item.total,
          isUpload: false,
          isDirect: true,
          needsAccept: item.needsAccept,
        )
        .._done = item.done
        .._error = item.error,
  ];

  /// 一个会话里各条文件消息对应的本地文件：发出的是源文件，收到的是保存位置。
  Future<Map<String, String>> localPaths(String sessionId) =>
      LocalDatabase.getFilePaths(sessionId);

  /// 经 WebRTC 数据通道把 [file] 发给 [contact]，成功后再发一条文件消息。
  /// 成功返回消息 ID；失败（原因在 [uploads] 的状态里）或被取消返回 null。
  Future<String?> sendDirect(Contact contact, File file) =>
      _send(contact, file, viaDirect: true);

  /// 把 [file] 加密后传到中继，并给 [contact] 发一条文件消息。
  /// 调用方须已得到用户确认。成功返回消息 ID；失败或被取消返回 null。
  Future<String?> sendViaRelay(Contact contact, File file) =>
      _send(contact, file, viaDirect: false);

  Future<String?> _send(Contact contact, File file, {required bool viaDirect}) async {
    final sessionId = contact.sessionId;
    final total = await _lengthOrZero(file);
    final state = FileTransferState._(
      id: MessageCodec.newMessageId(),
      sessionId: sessionId,
      name: p.basename(file.path),
      total: total,
      isUpload: true,
      isDirect: viaDirect,
    );
    _uploads[state.id] = state;
    _notify(sessionId);
    try {
      if (viaDirect && state.total > FileCipher.maxDirectFileBytes) {
        throw const FileTransferException('too-large-direct');
      }
      if (!viaDirect && state.total > FileCipher.maxFileBytes) {
        throw const FileTransferException('too-large');
      }
      final FileOffer offer;
      if (viaDirect) {
        if (direct == null) throw const FileTransferException('failed');
        offer = await direct!.send(
          contact: contact,
          file: file,
          cancel: state._cancel,
          onProgress: (done, _) => _progress(state, done),
        );
      } else {
        final auth = _authOf(contact);
        offer = await transfer.upload(
          file,
          auth: auth,
          cancel: state._cancel,
          onProgress: (done, _) => _progress(state, done),
        );
      }
      final String msgId;
      try {
        msgId = await messaging.sendFile(contact, offer);
      } catch (_) {
        if (!offer.isDirect) {
          await transfer.discard(
            offer.fileId,
            auth: _authOf(contact),
          ); // 消息没发出去，对方永远不会来取
        }
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
  Future<File?> download(
    Contact contact,
    ChatMessage message,
    File target,
  ) async {
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
        auth: _authOf(contact),
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

  /// 接受一条大文件来传，保存到 [target]。成功返回保存的文件；失败或取消返回 null。
  Future<File?> acceptIncoming(String id, File target) async {
    final service = direct;
    if (service == null) return null;
    try {
      final saved = await service.accept(id, target);
      return saved;
    } on TransferCancelled {
      return null;
    } on FileTransferException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 拒绝一条待接受的大文件来传。
  void declineIncoming(String id) => direct?.decline(id);

  /// 取消一次进行中的传输，或清掉一条失败记录。[id] 是 [FileTransferState.id]。
  void cancel(String id) {
    final state = _uploads[id] ?? _downloads[id];
    if (state != null) {
      state._cancel.cancel();
      if (state.isDirect && state.isUpload) direct?.cancelActive();
      if (state.failed) {
        _remove(state);
        _notify(state.sessionId);
      }
      return;
    }
    direct?.cancel(id);
  }

  /// 取消一个会话的全部传输（删除联系人时调用）。
  void cancelSession(String sessionId) {
    for (final state in [..._uploads.values, ..._downloads.values]) {
      if (state.sessionId == sessionId) _drop(state);
    }
    direct?.cancelSession(sessionId);
    _notify(sessionId);
  }

  /// 取消全部传输（清空全部数据时调用）。
  void reset() {
    final all = [..._uploads.values, ..._downloads.values];
    all.forEach(_drop);
    direct?.reset();
    for (final sessionId in {for (final state in all) state.sessionId}) {
      _notify(sessionId);
    }
  }

  Future<void> dispose() async {
    reset();
    for (final sub in _subs) {
      await sub.cancel();
    }
    await _incomingArrivals.close();
    await _updates.close();
  }

  void _onDirectUpdate(String sessionId) {
    _notify(sessionId);
    unawaited(_bindPendingPaths(sessionId));
    _announceIncoming(sessionId);
  }

  void _announceIncoming(String sessionId) {
    final current = {
      for (final item in incoming(sessionId))
        if (item.needsAccept) item.id,
    };
    final previous = _announcedIncoming.putIfAbsent(sessionId, () => <String>{});
    for (final id in current) {
      if (previous.add(id) && !_incomingArrivals.isClosed) {
        _incomingArrivals.add(sessionId);
      }
    }
    previous.removeWhere((id) => !current.contains(id));
  }

  Future<void> _bindPendingPaths(String sessionId) async {
    final pending = direct?.pendingPaths;
    if (pending == null || pending.isEmpty) return;
    await _bindPendingForSession(sessionId, pending);
  }

  Future<void> _bindPendingForSession(
    String sessionId,
    Map<String, String> pending, {
    Contact? contact,
  }) async {
    Contact? found = contact;
    if (found == null) {
      for (final item in await ContactStore.getAllContacts()) {
        if (item.sessionId == sessionId) {
          found = item;
          break;
        }
      }
    }
    if (found == null) return;
    List<ChatMessage> messages;
    try {
      messages = await messaging.messages(found);
    } catch (_) {
      return;
    }
    var changed = false;
    for (final message in messages) {
      final offer = message.file;
      if (offer == null) continue;
      final path = pending[offer.fileId];
      if (path == null) continue;
      try {
        await LocalDatabase.setFilePath(message.id, path);
        direct?.forgetPendingPath(offer.fileId);
        changed = true;
      } catch (_) {}
    }
    if (changed) _notify(sessionId);
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

  static FileRelayAuth _authOf(Contact contact) =>
      FileRelayAuth(sessionId: contact.sessionId, peer: contact.peerRole);

  static Future<int> _lengthOrZero(File file) async {
    try {
      return await file.length();
    } on FileSystemException {
      return 0;
    }
  }
}
