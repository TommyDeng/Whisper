/// 大文件直传的状态机：信令、ICE、数据通道上的分块收发。
///
/// 信令经 [FileDirectTransport] 收发（加密临时消息），通道经 [FileDirectLink]
///（WebRTC 数据通道，无音视频）。状态机本身不碰网络和设备。
/// 行为说明见 docs/file-direct.md。
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../call/call_signal.dart';
import '../contact/contact.dart';
import '../messaging/message_codec.dart';
import '../voice/ice_strategy.dart';
import 'file_cipher.dart';
import 'file_direct_link.dart';
import 'file_direct_protocol.dart';
import 'file_direct_signal.dart';
import 'file_offer.dart';
import 'file_relay_transfer.dart';

/// 收到的一条直传信令：谁发的、内容（未校验）。
class IncomingFileSignal {
  const IncomingFileSignal(this.contact, this.body);

  final Contact contact;
  final String body;
}

/// 直传信令的收发通道。
abstract class FileDirectTransport {
  Future<String?> send(Contact contact, String body);

  Stream<IncomingFileSignal> get incoming;

  Stream<({String sessionId, String id})> get dropped;
}

/// 一条尚未变成聊天消息的来传（待接受、进行中或刚失败）。
class FileDirectIncoming {
  FileDirectIncoming._({
    required this.id,
    required this.contact,
    required this.offer,
  });

  final String id;
  final Contact contact;
  final FileOffer offer;

  bool _accepted = false;
  int _done = 0;
  String? _error;
  String? _sdp;
  Timer? _timer;

  String get sessionId => contact.sessionId;

  String get name => offer.safeName;

  int get total => offer.size;

  int get done => _done;

  String? get error => _error;

  bool get failed => _error != null;

  /// 还在等用户选保存位置。
  bool get needsAccept => !_accepted && _error == null;
}

class FileDirectService {
  FileDirectService({
    required this.transport,
    required this.createLink,
    this.offerTimeout = const Duration(seconds: 120),
    this.connectTimeout = const Duration(seconds: 30),
    this.progressTimeout = const Duration(seconds: 60),
  }) {
    _transportSubs.add(transport.incoming.listen(_onIncoming));
    _transportSubs.add(transport.dropped.listen(_onDropped));
  }

  final FileDirectTransport transport;
  final FileDirectLink Function() createLink;
  final Duration offerTimeout;
  final Duration connectTimeout;
  final Duration progressTimeout;

  final _updates = StreamController<String>.broadcast();
  final _transportSubs = <StreamSubscription<dynamic>>[];
  final _endedIds = <String>[];
  final _incoming = <String, FileDirectIncoming>{};
  final _pendingPaths = <String, String>{}; // fileId → 本地路径
  final _pendingCandidates = <String, List<CallCandidate>>{};

  _Live? _live;
  bool _disposed = false;

  Stream<String> get updates => _updates.stream;

  /// 一个会话里待接受、进行中和失败的来传。
  List<FileDirectIncoming> incoming(String sessionId) => [
    for (final item in _incoming.values)
      if (item.sessionId == sessionId) item,
  ];

  /// 直传刚完成、对应的文件消息还没落到本地记录时的路径。
  Map<String, String> get pendingPaths => Map.unmodifiable(_pendingPaths);

  void forgetPendingPath(String fileId) => _pendingPaths.remove(fileId);

  /// 把 [file] 经数据通道发给 [contact]，成功返回文件描述（调用方再发文件消息）。
  Future<FileOffer> send({
    required Contact contact,
    required File file,
    CancelToken? cancel,
    TransferProgress? onProgress,
  }) async {
    if (_live != null ||
        _incoming.values.any(
          (item) => item.needsAccept || item._accepted && !item.failed,
        )) {
      throw const FileTransferException('busy');
    }
    final size = await file.length();
    if (size > FileCipher.maxDirectFileBytes) {
      throw const FileTransferException('too-large-direct');
    }
    final keys = FileKeys.random();
    final hash = await FileCipher.hashFile(file);
    _throwIfCancelled(cancel);
    final offer = FileOffer(
      fileId: FileOffer.newFileId(),
      name: p.basename(file.path),
      size: size,
      keys: keys,
      hash: hash,
      via: FileTransferVia.direct,
    );

    final live = _Live(
      contact: contact,
      xferId: MessageCodec.newMessageId(),
      outgoing: true,
      offer: offer,
      source: file,
      cancel: cancel,
      onProgress: onProgress,
    );
    _live = live;

    try {
      final link = createLink();
      live.link = link;
      _listenLink(live);
      final sdp = await link.createOffer();
      _throwIfCancelled(cancel);
      live.localReady = true;
      final id = await transport.send(
        contact,
        FileDirectSignal.offer(live.xferId, sdp, offer).encode(),
      );
      if (id == null) throw const FileTransferException('offline');
      live.offerMessageId = id;
      await _flushLocalCandidates(live);
      _armOfferTimer(live);

      final answer = await live.wait(live.answered);
      live.offerTimer?.cancel();
      await link.acceptAnswer(answer.sdp!);
      live.acceptDone = true;
      await _flushRemoteCandidates(live);
      _armConnectTimer(live);

      await live.wait(live.connected);
      live.connectTimer?.cancel();
      await _rejectRelay(live);

      final startAt = await live.wait(live.started);
      _armProgressTimer(live);
      await _pump(live, startAt);
      await live.wait(live.finished);
      _disarmProgress(live);
      await _endLive(sendEnd: false);
      return offer;
    } on TransferCancelled {
      await _endLive(reason: FileDirectSignal.reasonCancel);
      rethrow;
    } on FileTransferException catch (error) {
      await _endLive(reason: _endReason(error.code));
      rethrow;
    } catch (_) {
      await _endLive(reason: FileDirectSignal.reasonFailed);
      throw const FileTransferException('failed');
    }
  }

  /// 接受一条来传并保存到 [target]。成功返回保存的文件。
  Future<File?> accept(
    String xferId,
    File target, {
    CancelToken? cancel,
    TransferProgress? onProgress,
  }) async {
    final incoming = _incoming[xferId];
    if (incoming == null || !incoming.needsAccept) {
      throw StateError('没有待接受的直传');
    }
    if (_live != null) throw const FileTransferException('busy');

    incoming._accepted = true;
    _notify();

    final live = _Live(
      contact: incoming.contact,
      xferId: xferId,
      outgoing: false,
      offer: incoming.offer,
      cancel: cancel,
      onProgress: onProgress,
      incoming: incoming,
    );
    live.remoteSdp = incoming._sdp;
    live.remoteCandidates.addAll(_pendingCandidates.remove(xferId) ?? const []);
    _live = live;

    try {
      final link = createLink();
      live.link = link;
      _listenLink(live);
      final sdp = await link.acceptOffer(live.remoteSdp!);
      _throwIfCancelled(cancel);
      live.acceptDone = true;
      await _flushRemoteCandidates(live);
      final sent = await transport.send(
        incoming.contact,
        FileDirectSignal.answer(xferId, sdp).encode(),
      );
      if (sent == null) throw const FileTransferException('offline');
      live.localReady = true;
      await _flushLocalCandidates(live);
      _armConnectTimer(live);

      await live.wait(live.connected);
      live.connectTimer?.cancel();
      await _rejectRelay(live);

      final receiver = await FileReceiver.open(
        target: target,
        keys: incoming.offer.keys,
        size: incoming.offer.size,
        hash: incoming.offer.hash,
      );
      live.receiver = receiver;
      _armProgressTimer(live);
      await link.sendText(FileDirectProtocol.start(receiver.nextIndex));
      if (receiver.nextIndex >= receiver.chunkCount) {
        await _finishReceive(live);
      }
      await live.wait(live.finished);
      _disarmProgress(live);
      final saved = live.saved!;
      _pendingPaths[incoming.offer.fileId] = saved.absolute.path;
      _incoming.remove(xferId);
      await _endLive(sendEnd: false);
      _notify();
      return saved;
    } on TransferCancelled {
      await live.receiver?.close();
      incoming._timer?.cancel();
      _incoming.remove(xferId);
      await _endLive(reason: FileDirectSignal.reasonCancel);
      _notify();
      rethrow;
    } on FileTransferException catch (error) {
      incoming._error = error.code;
      await _endLive(reason: _endReason(error.code));
      _notify();
      rethrow;
    } catch (_) {
      incoming._error = 'failed';
      await _endLive(reason: FileDirectSignal.reasonFailed);
      _notify();
      throw const FileTransferException('failed');
    }
  }

  /// 拒绝一条待接受的来传（从列表里拿掉，并通知对方）。
  void decline(String xferId) {
    final incoming = _incoming[xferId];
    if (incoming == null || !incoming.needsAccept) return;
    incoming._timer?.cancel();
    _incoming.remove(xferId);
    _pendingCandidates.remove(xferId);
    _rememberEnded(xferId);
    unawaited(
      transport.send(
        incoming.contact,
        FileDirectSignal.end(xferId, FileDirectSignal.reasonReject).encode(),
      ),
    );
    _notify();
  }

  /// 取消当前正在进行的直传（呼出或已接受的来传）。
  void cancelActive() {
    final live = _live;
    if (live == null) return;
    live.cancel?.cancel();
    live.fail(const TransferCancelled());
  }

  /// 取消进行中的呼出或来传；或清掉一条失败的来传记录。
  void cancel(String id) {
    final live = _live;
    if (live != null && live.xferId == id) {
      cancelActive();
      return;
    }
    final incoming = _incoming[id];
    if (incoming == null) return;
    incoming._timer?.cancel();
    if (incoming.needsAccept) {
      unawaited(
        transport.send(
          incoming.contact,
          FileDirectSignal.end(id, FileDirectSignal.reasonReject).encode(),
        ),
      );
      _rememberEnded(id);
    }
    _incoming.remove(id);
    _pendingCandidates.remove(id);
    _notify();
  }

  void cancelSession(String sessionId) {
    if (_live?.contact.sessionId == sessionId) {
      cancel(_live!.xferId);
    }
    for (final item in _incoming.values.toList()) {
      if (item.sessionId == sessionId) {
        if (item.needsAccept) decline(item.id);
        item._timer?.cancel();
        _incoming.remove(item.id);
      }
    }
    _notify();
  }

  void reset() {
    final live = _live;
    if (live != null) cancel(live.xferId);
    for (final item in _incoming.values.toList()) {
      item._timer?.cancel();
    }
    _incoming.clear();
    _pendingCandidates.clear();
    _pendingPaths.clear();
    _notify();
  }

  Future<void> dispose() async {
    _disposed = true;
    reset();
    for (final sub in _transportSubs) {
      await sub.cancel();
    }
    await _updates.close();
  }

  // ---------------------------------------------------------------------------

  void _onIncoming(IncomingFileSignal incoming) {
    if (_disposed) return;
    final signal = FileDirectSignal.decode(incoming.body);
    if (signal == null) return;
    final live = _live;

    if (signal.kind == FileDirectSignal.kindOffer) {
      if (_endedIds.contains(signal.xferId)) return;
      if (live != null) {
        if (live.xferId == signal.xferId &&
            live.contact.sessionId == incoming.contact.sessionId) {
          return;
        }
        unawaited(
          transport.send(
            incoming.contact,
            FileDirectSignal.end(
              signal.xferId,
              FileDirectSignal.reasonBusy,
            ).encode(),
          ),
        );
        return;
      }
      if (_incoming.values.any(
        (item) => item.needsAccept || (item._accepted && !item.failed),
      )) {
        unawaited(
          transport.send(
            incoming.contact,
            FileDirectSignal.end(
              signal.xferId,
              FileDirectSignal.reasonBusy,
            ).encode(),
          ),
        );
        return;
      }
      final item = FileDirectIncoming._(
        id: signal.xferId,
        contact: incoming.contact,
        offer: signal.file!,
      );
      item._sdp = signal.sdp;
      item._timer = Timer(offerTimeout, () {
        if (!item.needsAccept) return;
        item._error = 'timeout';
        _rememberEnded(item.id);
        _notify();
      });
      _incoming[item.id] = item;
      _notify();
      return;
    }

    // 其余信令必须属于当前这次直传，或属于一条待接受来传的候选。
    if (live != null &&
        live.xferId == signal.xferId &&
        live.contact.sessionId == incoming.contact.sessionId) {
      unawaited(_onLiveSignal(live, signal));
      return;
    }
    if (signal.kind == FileDirectSignal.kindCandidate) {
      final pending = _incoming[signal.xferId];
      if (pending != null &&
          pending.needsAccept &&
          pending.sessionId == incoming.contact.sessionId) {
        _pendingCandidates
            .putIfAbsent(signal.xferId, () => [])
            .add(signal.candidate!);
      }
    }
    if (signal.kind == FileDirectSignal.kindEnd) {
      final pending = _incoming[signal.xferId];
      if (pending != null &&
          pending.sessionId == incoming.contact.sessionId &&
          !pending._accepted) {
        pending._error = _errorForRemoteEnd(signal.reason);
        pending._timer?.cancel();
        _rememberEnded(signal.xferId);
        _notify();
      }
    }
  }

  void _onDropped(({String sessionId, String id}) event) {
    final live = _live;
    if (live == null || !live.outgoing) return;
    if (live.contact.sessionId != event.sessionId) return;
    if (live.offerMessageId != event.id) return;
    live.fail(const FileTransferException('offline'));
  }

  Future<void> _onLiveSignal(_Live live, FileDirectSignal signal) async {
    switch (signal.kind) {
      case FileDirectSignal.kindAnswer:
        if (!live.outgoing || live.answered.isCompleted) return;
        live.answered.complete(signal);
      case FileDirectSignal.kindCandidate:
        if (live.acceptDone) {
          await live.link?.addCandidate(signal.candidate!);
        } else {
          live.remoteCandidates.add(signal.candidate!);
        }
      case FileDirectSignal.kindEnd:
        live.fail(FileTransferException(_errorForRemoteEnd(signal.reason)));
    }
  }

  void _listenLink(_Live live) {
    final link = live.link!;
    live.subs.add(
      link.candidates.listen((candidate) {
        if (live.localReady) {
          unawaited(
            transport.send(
              live.contact,
              FileDirectSignal.candidate(live.xferId, candidate).encode(),
            ),
          );
        } else {
          live.localCandidates.add(candidate);
        }
      }),
    );
    live.subs.add(
      link.states.listen((state) {
        switch (state) {
          case FileLinkState.connected:
            if (!live.connected.isCompleted) live.connected.complete();
          case FileLinkState.failed:
          case FileLinkState.closed:
            live.fail(const FileTransferException('network'));
        }
      }),
    );
    live.subs.add(
      link.paths.listen((path) {
        if (path == IcePathType.relay) {
          live.fail(const FileTransferException('no-direct'));
        }
      }),
    );
    live.subs.add(
      link.messages.listen(
        (message) => unawaited(_onChannelMessage(live, message)),
      ),
    );
  }

  Future<void> _onChannelMessage(_Live live, FileLinkMessage message) async {
    try {
      if (message.isBinary) {
        if (live.outgoing || live.receiver == null) return;
        final sealed = live.reassembler.add(message.bytes!);
        if (sealed == null) return;
        final index = live.receiver!.nextIndex;
        await live.receiver!.addChunk(index, sealed);
        _throwIfCancelled(live.cancel);
        await live.link?.sendText(FileDirectProtocol.ack(index));
        final done = index + 1 == live.receiver!.chunkCount
            ? live.offer!.size
            : (index + 1) * FileCipher.chunkSize;
        live.incoming?._done = done;
        live.onProgress?.call(done, live.offer!.size);
        _armProgressTimer(live);
        if (live.receiver!.nextIndex >= live.receiver!.chunkCount) {
          await _finishReceive(live);
        }
        return;
      }
      final control = FileDirectControl.parse(message.text ?? '');
      if (control == null) return;
      switch (control.type) {
        case FileDirectProtocol.typeStart:
          if (live.outgoing && !live.started.isCompleted) {
            live.started.complete(control.index!);
          }
        case FileDirectProtocol.typeAck:
          if (live.outgoing &&
              live.expectingAck == control.index &&
              !live.acked.isCompleted) {
            live.acked.complete();
          }
        case FileDirectProtocol.typeDone:
          if (live.outgoing && !live.finished.isCompleted) {
            live.finished.complete();
          }
        case FileDirectProtocol.typeFail:
          live.fail(
            FileTransferException(
              control.reason == 'corrupt' ? 'corrupt' : 'failed',
            ),
          );
        case FileDirectProtocol.typeAbort:
          live.fail(const FileTransferException('network'));
      }
    } on FileCipherException {
      live.fail(const FileTransferException('corrupt'));
      try {
        await live.link?.sendText(FileDirectProtocol.fail('corrupt'));
      } catch (_) {}
    } on TransferCancelled {
      live.fail(const TransferCancelled());
    } catch (_) {
      live.fail(const FileTransferException('failed'));
    }
  }

  Future<void> _pump(_Live live, int startAt) async {
    final file = live.source!;
    final offer = live.offer!;
    final count = FileCipher.chunkCount(offer.size);
    if (startAt > count) throw const FileTransferException('failed');
    if (startAt == count) {
      // 对方已经收齐，等 done
      return;
    }
    for (var index = startAt; index < count; index++) {
      _throwIfCancelled(live.cancel);
      if (live.failed != null) throw live.failed!;
      final current = await file.length();
      if (current != offer.size) throw const FileTransferException('changed');
      final sealed = await FileCipher.sealChunk(file, offer.keys, index);
      live.acked = Completer<void>();
      live.expectingAck = index;
      for (final fragment in FileDirectProtocol.fragments(index, sealed)) {
        _throwIfCancelled(live.cancel);
        if (await live.link!.bufferedAmount() >= FileDirectProtocol.highWater) {
          await live.link!.waitForDrain();
        }
        await live.link!.sendBinary(fragment);
      }
      await live.wait(live.acked);
      final done = index + 1 == count
          ? offer.size
          : (index + 1) * FileCipher.chunkSize;
      live.onProgress?.call(done, offer.size);
      _armProgressTimer(live);
    }
  }

  Future<void> _finishReceive(_Live live) async {
    final saved = await live.receiver!.finish();
    live.receiver = null;
    live.saved = saved;
    await live.link?.sendText(FileDirectProtocol.done());
    if (!live.finished.isCompleted) live.finished.complete();
  }

  Future<void> _rejectRelay(_Live live) async {
    final path = await live.link?.currentPath();
    if (path == IcePathType.relay) {
      throw const FileTransferException('no-direct');
    }
  }

  Future<void> _flushLocalCandidates(_Live live) async {
    final pending = List<CallCandidate>.from(live.localCandidates);
    live.localCandidates.clear();
    for (final candidate in pending) {
      await transport.send(
        live.contact,
        FileDirectSignal.candidate(live.xferId, candidate).encode(),
      );
    }
  }

  Future<void> _flushRemoteCandidates(_Live live) async {
    final pending = List<CallCandidate>.from(live.remoteCandidates);
    live.remoteCandidates.clear();
    for (final candidate in pending) {
      await live.link?.addCandidate(candidate);
    }
  }

  void _armOfferTimer(_Live live) {
    live.offerTimer?.cancel();
    live.offerTimer = Timer(offerTimeout, () {
      live.fail(const FileTransferException('timeout'));
    });
  }

  void _armConnectTimer(_Live live) {
    live.connectTimer?.cancel();
    live.connectTimer = Timer(connectTimeout, () {
      live.fail(const FileTransferException('network'));
    });
  }

  void _armProgressTimer(_Live live) {
    live.progressTimer?.cancel();
    live.progressTimer = Timer(progressTimeout, () {
      live.fail(const FileTransferException('network'));
    });
  }

  void _disarmProgress(_Live live) => live.progressTimer?.cancel();


  Future<void> _dropReceiver(_Live live, {required bool deletePart}) async {
    final receiver = live.receiver;
    final partPath = receiver == null ? null : '${receiver.target.path}.part';
    live.receiver = null;
    if (receiver != null) {
      try {
        if (deletePart) {
          await receiver.abort();
        } else {
          await receiver.close();
        }
      } catch (_) {}
    }
    if (deletePart && partPath != null) {
      try {
        final part = File(partPath);
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
  }

  Future<void>? _ending;

  Future<void> _endLive({String? reason, bool sendEnd = true}) async {
    final inflight = _ending;
    if (inflight != null) {
      await inflight;
      return;
    }
    final done = Completer<void>();
    _ending = done.future;
    try {
      await _endLiveBody(reason: reason, sendEnd: sendEnd);
    } finally {
      _ending = null;
      if (!done.isCompleted) done.complete();
    }
  }

  Future<void> _endLiveBody({String? reason, bool sendEnd = true}) async {
    final live = _live;
    if (live == null) return;
    live.offerTimer?.cancel();
    live.connectTimer?.cancel();
    live.progressTimer?.cancel();
    _rememberEnded(live.xferId);
    if (sendEnd && reason != null) {
      try {
        if (live.link != null) {
          try {
            await live.link!.sendText(FileDirectProtocol.abort());
          } catch (_) {}
        }
        await transport.send(
          live.contact,
          FileDirectSignal.end(live.xferId, reason).encode(),
        );
      } catch (_) {}
    }
    final error = live.failed;
    final deletePart = error is FileTransferException && error.code == 'corrupt';
    await _dropReceiver(live, deletePart: deletePart);
    for (final sub in live.subs) {
      await sub.cancel();
    }
    try {
      await live.link?.close();
    } catch (_) {}
    if (live.failed == null && !live.finished.isCompleted) {
      live.fail(const FileTransferException('failed'));
    }
    if (identical(_live, live)) _live = null;
  }

  void _rememberEnded(String xferId) {
    _endedIds.remove(xferId);
    _endedIds.add(xferId);
    while (_endedIds.length > 64) {
      _endedIds.removeAt(0);
    }
  }

  void _notify([String? sessionId]) {
    if (_updates.isClosed) return;
    if (sessionId != null) {
      _updates.add(sessionId);
      return;
    }
    if (_live != null) _updates.add(_live!.contact.sessionId);
    for (final item in _incoming.values) {
      _updates.add(item.sessionId);
    }
  }

  static String _endReason(String code) {
    return switch (code) {
      'no-direct' => FileDirectSignal.reasonNoDirect,
      'busy' => FileDirectSignal.reasonBusy,
      'declined' => FileDirectSignal.reasonReject,
      'offline' ||
      'timeout' ||
      'network' ||
      'changed' ||
      'corrupt' ||
      'failed' => FileDirectSignal.reasonFailed,
      _ => FileDirectSignal.reasonCancel,
    };
  }

  static String _errorForRemoteEnd(String? reason) {
    return switch (reason) {
      FileDirectSignal.reasonReject => 'declined',
      FileDirectSignal.reasonBusy => 'busy',
      FileDirectSignal.reasonNoDirect => 'no-direct',
      FileDirectSignal.reasonFailed => 'failed',
      _ => 'network',
    };
  }

  static void _throwIfCancelled(CancelToken? cancel) {
    if (cancel != null && cancel.isCancelled) throw const TransferCancelled();
  }
}

class _Live {
  _Live({
    required this.contact,
    required this.xferId,
    required this.outgoing,
    required this.offer,
    this.source,
    this.cancel,
    this.onProgress,
    this.incoming,
  });

  final Contact contact;
  final String xferId;
  final bool outgoing;
  final FileOffer? offer;
  final File? source;
  final CancelToken? cancel;
  final TransferProgress? onProgress;
  final FileDirectIncoming? incoming;

  FileDirectLink? link;
  FileReceiver? receiver;
  File? saved;
  String? offerMessageId;
  String? remoteSdp;
  bool localReady = false;
  bool acceptDone = false;
  int expectingAck = -1;
  Object? failed;

  final localCandidates = <CallCandidate>[];
  final remoteCandidates = <CallCandidate>[];
  final subs = <StreamSubscription<dynamic>>[];
  final reassembler = ChunkReassembler();

  final answered = Completer<FileDirectSignal>();
  final connected = Completer<void>();
  final started = Completer<int>();
  Completer<void> acked = Completer<void>();
  final finished = Completer<void>();

  Timer? offerTimer;
  Timer? connectTimer;
  Timer? progressTimer;

  final aborted = Completer<void>();

  void fail(Object error) {
    if (failed != null) return;
    failed = error;
    if (!aborted.isCompleted) aborted.complete();
  }

  /// 等到 [completer] 完成；若传输已被失败/取消，则抛出那个错误。
  Future<T> wait<T>(Completer<T> completer) async {
    if (failed != null) throw failed!;
    if (completer.isCompleted) return completer.future;
    await Future.any([completer.future, aborted.future]);
    if (failed != null) throw failed!;
    return completer.future;
  }
}
