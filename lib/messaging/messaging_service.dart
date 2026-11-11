/// 消息服务：每位联系人一条会话中继连接，负责加密发送、解密接收、落库和状态更新。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../contact/contact.dart';
import '../e2ee/message.dart';
import '../identity/identity_store.dart';
import '../relay/relay_transport.dart';
import '../relay/session_client.dart';
import '../storage/local_db.dart';
import 'message_codec.dart';

/// 自己发出的消息的状态。
enum OutgoingStatus { sending, sent, delivered, failed }

/// 界面上的一条消息（已解密）。
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.isSent,
    required this.timestamp,
    required this.text,
    this.status,
    this.burn = false,
  });

  final String id;
  final bool isSent;
  final int timestamp;

  /// 正文。解不开（例如身份已重置）时为 null。
  final String? text;

  /// 仅自己发出的消息有。
  final OutgoingStatus? status;

  /// 阅后即焚的消息。
  final bool burn;
}

class _Session {
  _Session(this.contact, this.client, this.key);

  final Contact contact;
  final SessionClient client;
  final Future<SecretKey> key;
  final List<StreamSubscription<void>> subscriptions = [];
}

class MessagingService {
  MessagingService({
    required this.baseUri,
    required this.connector,
    required this.identity,
    this.backoff,
  });

  final Uri baseUri;
  final RelayConnector connector;
  final Future<IdentityKeyPair> Function() identity;

  /// 重连退避，测试用；为 null 时用 [SessionClient] 的默认值。
  final List<Duration>? backoff;

  final Map<String, _Session> _sessions = {}; // 以 sessionId 为键
  final Map<String, String> _plaintext = {}; // msgId → 正文
  final Set<String> _failed = {};
  final _updates = StreamController<String>.broadcast();
  bool _started = false;

  /// 某个会话有变化（新消息、状态、连接、对方在线）时发出它的 sessionId。
  Stream<String> get updates => _updates.stream;

  /// 为所有已有会话的联系人建立连接。重复调用无效果。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    for (final contact in await ContactStore.getAllContacts()) {
      await attach(contact);
    }
  }

  /// 为一位联系人建立（或重建）连接，并重发中继还没收下的消息。
  Future<void> attach(Contact contact) async {
    if (!contact.hasSession) return;
    await _close(contact.sessionId);

    final key = _deriveKey(contact);
    // 密钥算不出来（对方公钥有问题）时不在这里抛，收发时各自处理
    unawaited(key.then<void>((_) {}, onError: (_) {}));

    late final _Session session;
    final client = SessionClient(
      baseUri: baseUri,
      sessionId: contact.sessionId,
      peer: contact.peerRole,
      connector: connector,
      onMessage: (message) => _onMessage(session, message),
      backoff: backoff ??
          const [
            Duration(seconds: 1),
            Duration(seconds: 2),
            Duration(seconds: 5),
            Duration(seconds: 15),
            Duration(seconds: 30),
          ],
    );
    session = _Session(contact, client, key);
    _sessions[contact.sessionId] = session;

    final sessionId = contact.sessionId;
    session.subscriptions.addAll([
      client.states.listen((_) => _notify(sessionId)),
      client.peerOnlineChanges.listen((_) => _notify(sessionId)),
      client.stored.listen((id) async {
        await LocalDatabase.markRelayed(id);
        await LocalDatabase.deleteOutbox(id);
        _notify(sessionId);
      }),
      client.delivered.listen((id) async {
        await LocalDatabase.markDelivered(id);
        _notify(sessionId);
      }),
      client.errors.listen((error) async {
        final id = error.id;
        if (id == null) return;
        if (const {'bad-id', 'bad-payload', 'too-large'}.contains(error.error)) {
          _failed.add(id);
          await LocalDatabase.deleteOutbox(id);
          _notify(sessionId);
        }
      }),
    ]);

    for (final message in await LocalDatabase.getUnrelayedMessages(sessionId)) {
      client.send(message.msgId, message.ciphertext);
    }
    // 回执在中继确认收下之前必须熬得过重启：按原值原样重发。
    for (final receipt in await LocalDatabase.queryOutbox(sessionId)) {
      client.send(
        receipt['msgId'] as String,
        receipt['payload'] as String,
      );
    }
    client.start();
    _notify(sessionId);
  }

  /// 断开一位联系人的连接。
  Future<void> detach(Contact contact) => _close(contact.sessionId);

  /// 删除联系人时调用：断开连接并删掉这个会话的本地消息和待发回执。
  Future<void> forget(Contact contact) async {
    await _close(contact.sessionId);
    if (contact.sessionId.isNotEmpty) {
      await LocalDatabase.deleteSessionMessages(contact.sessionId);
      await LocalDatabase.deleteOutboxForSession(contact.sessionId);
    }
  }

  SessionLinkState linkState(String sessionId) =>
      _sessions[sessionId]?.client.state ?? SessionLinkState.disconnected;

  bool peerOnline(String sessionId) => _sessions[sessionId]?.client.peerOnline ?? false;

  /// 发送一条文本。先落库再交给中继；离线时留在待发队列里，连上后自动发出。
  /// [burn] 为 true 时这条消息是阅后即焚的：对方读过之后两边都删除。
  Future<void> sendText(Contact contact, String text, {bool burn = false}) async {
    final session = _sessions[contact.sessionId];
    if (session == null) throw StateError('联系人没有可用的会话');
    final me = await identity();
    final id = MessageCodec.newMessageId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = await MessageCodec.seal(
      key: await session.key,
      sessionId: contact.sessionId,
      senderRole: contact.peerRole,
      messageId: id,
      content: ChatContent.text(text, sentAt: now, burn: burn),
    );
    await LocalDatabase.insertMessage(StoredMessage(
      msgId: id,
      sessionId: contact.sessionId,
      senderPublicKey: me.x25519PublicKeyBase64,
      ciphertext: payload,
      sequenceNumber: 0,
      timestamp: now,
      direction: 'sent',
      burnAfterRead: burn,
    ));
    _plaintext[id] = text;
    await ContactStore.updateContactLastMessageTime(contact.deviceId, now);
    // 落库期间会话可能已被替换或关闭；新会话 attach 时会从库里捡起这条
    if (identical(_sessions[contact.sessionId], session)) session.client.send(id, payload);
    _notify(contact.sessionId);
  }

  /// 加密一条发给对方的回执，返回它的 id 和密文。
  Future<({String msgId, String payload})> _sealReceipt(Contact contact, ChatContent receipt) async {
    final id = MessageCodec.newMessageId();
    final payload = await MessageCodec.seal(
      key: await (_sessions[contact.sessionId]?.key ?? _deriveKey(contact)),
      sessionId: contact.sessionId,
      senderRole: contact.peerRole,
      messageId: id,
      content: receipt,
    );
    return (msgId: id, payload: payload);
  }

  /// 会话连着就把回执交给中继；没连着时它留在 outbox 里，下次 [attach] 发出。
  void _trySend(String sessionId, ({String msgId, String payload}) receipt) {
    _sessions[sessionId]?.client.send(receipt.msgId, receipt.payload);
  }

  /// 一个会话的全部消息，已解密，按时间升序。
  Future<List<ChatMessage>> messages(Contact contact) async {
    final stored = await LocalDatabase.getSessionMessages(contact.sessionId);
    final result = <ChatMessage>[];
    for (final message in stored) {
      final isSent = message.direction == 'sent';
      result.add(ChatMessage(
        id: message.msgId,
        isSent: isSent,
        timestamp: message.timestamp,
        text: await _read(contact, message),
        status: isSent ? _status(message) : null,
        burn: message.burnAfterRead,
      ));
    }
    return result;
  }

  /// 把这个会话里收到的、还没读的消息标为已读（聊天界面显示它们时调用）。
  /// 其中阅后即焚的消息会给对方发一条 `read` 回执。
  Future<void> markRead(Contact contact) async {
    final unread = await LocalDatabase.getUnreadReceived(contact.sessionId);
    if (unread.isEmpty) return;
    final burned = [for (final message in unread) if (message.burn) message.msgId];
    final now = DateTime.now().millisecondsSinceEpoch;

    // 一条回执最多带 maxReceiptIds 个 id，多了拆成几条
    final receipts = <({String msgId, String payload})>[];
    for (var i = 0; i < burned.length; i += ChatContent.maxReceiptIds) {
      final end = i + ChatContent.maxReceiptIds;
      final batch = burned.sublist(i, end > burned.length ? burned.length : end);
      receipts.add(await _sealReceipt(
        contact,
        ChatContent.receipt(ChatContent.receiptRead, batch, sentAt: now),
      ));
    }
    await LocalDatabase.markReadWithReceipts(
      sessionId: contact.sessionId,
      msgIds: [for (final message in unread) message.msgId],
      receipts: receipts,
    );
    for (final receipt in receipts) {
      _trySend(contact.sessionId, receipt);
    }
    _notify(contact.sessionId);
  }

  /// 删除已读的、收到的阅后即焚消息（离开聊天界面和启动时调用）。
  /// [sessionId] 为 null 时处理所有会话。返回删除的条数。
  Future<int> purgeBurned({String? sessionId}) async {
    final affected = await LocalDatabase.deleteReadBurned(sessionId: sessionId);
    for (final row in affected) {
      _plaintext.remove(row['msgId'] as String);
    }
    for (final id in {for (final row in affected) row['sessionId'] as String}) {
      _notify(id);
    }
    return affected.length;
  }

  /// 删除超过 [retention] 的消息，不管读没读过、是不是阅后即焚（启动时和之后定时调用）。
  /// 返回删除的条数。
  Future<int> purgeExpired({DateTime? now, Duration retention = const Duration(days: 7)}) async {
    final cutoff = (now ?? DateTime.now()).subtract(retention).millisecondsSinceEpoch;
    final removed = await LocalDatabase.purgeExpired(cutoff);
    for (final message in removed) {
      _plaintext.remove(message.msgId);
      _failed.remove(message.msgId);
    }
    for (final id in {for (final message in removed) message.sessionId}) {
      _notify(id);
    }
    return removed.length;
  }

  /// 与同一个人重新配对后调用：把旧会话 [previous] 的聊天记录搬到新会话 [current] 名下。
  ///
  /// 密文绑定了会话 ID 和角色，所以要用旧密钥解开、再用新会话重新加密（msgId 不变）。
  /// 解不开的旧消息（例如自己的身份已重置）无法再显示，直接删除。
  /// 调用前后各自 [detach] 旧会话、[attach] 新会话；返回搬过来的条数。
  Future<int> adopt(Contact previous, Contact current) async {
    if (previous.sessionId.isEmpty || previous.sessionId == current.sessionId) return 0;
    final stored = await LocalDatabase.getSessionMessages(previous.sessionId);
    final rewritten = <String, String>{};
    if (stored.isNotEmpty) {
      try {
        final oldKey = await _deriveKey(previous);
        final newKey = await (_sessions[current.sessionId]?.key ?? _deriveKey(current));
        for (final message in stored) {
          final sent = message.direction == 'sent';
          try {
            final content = await MessageCodec.open(
              key: oldKey,
              sessionId: previous.sessionId,
              senderRole: sent ? previous.peerRole : previous.remoteRole,
              messageId: message.msgId,
              payload: message.ciphertext,
            );
            rewritten[message.msgId] = await MessageCodec.seal(
              key: newKey,
              sessionId: current.sessionId,
              senderRole: sent ? current.peerRole : current.remoteRole,
              messageId: message.msgId,
              content: content,
            );
          } catch (_) {
            // 这一条解不开，不搬
          }
        }
      } catch (_) {
        // 密钥算不出来：一条也搬不了
      }
    }
    await LocalDatabase.moveSessionMessages(
      fromSessionId: previous.sessionId,
      toSessionId: current.sessionId,
      rewritten: rewritten,
      peerPublicKey: current.x25519PublicKeyBase64,
    );
    for (final message in stored) {
      if (!rewritten.containsKey(message.msgId)) _plaintext.remove(message.msgId);
    }
    _notify(previous.sessionId);
    _notify(current.sessionId);
    return rewritten.length;
  }

  /// 清空全部数据时调用：断开所有连接、丢掉内存里的明文，回到 [start] 之前的状态。
  Future<void> reset() async {
    for (final sessionId in _sessions.keys.toList()) {
      await _close(sessionId);
    }
    _plaintext.clear();
    _failed.clear();
    _started = false;
  }

  Future<void> dispose() async {
    for (final sessionId in _sessions.keys.toList()) {
      await _close(sessionId);
    }
    await _updates.close();
  }

  // ---------------------------------------------------------------------------

  OutgoingStatus _status(StoredMessage message) {
    if (message.delivered) return OutgoingStatus.delivered;
    if (message.relayed) return OutgoingStatus.sent;
    if (_failed.contains(message.msgId)) return OutgoingStatus.failed;
    return OutgoingStatus.sending;
  }

  Future<SecretKey> _deriveKey(Contact contact) async {
    final me = await identity();
    return MessageCodec.deriveKey(
      myPrivateKey: me.x25519PrivateKey,
      peerPublicKey: Uint8List.fromList(
        base64Url.decode(base64Url.normalize(contact.x25519PublicKeyBase64)),
      ),
      sessionId: contact.sessionId,
    );
  }

  Future<String?> _read(Contact contact, StoredMessage message) async {
    final cached = _plaintext[message.msgId];
    if (cached != null) return cached;
    try {
      final key = await (_sessions[contact.sessionId]?.key ?? _deriveKey(contact));
      final content = await MessageCodec.open(
        key: key,
        sessionId: contact.sessionId,
        senderRole: message.direction == 'sent' ? contact.peerRole : contact.remoteRole,
        messageId: message.msgId,
        payload: message.ciphertext,
      );
      if (content.type != ChatContent.typeText) return null;
      return _plaintext[message.msgId] = content.body;
    } catch (_) {
      return null;
    }
  }

  /// 正常返回后 [SessionClient] 才向中继确认。解不开的消息也确认掉，
  /// 否则中继每次重连都会重投；落库失败则抛出，留给下次重投。
  Future<void> _onMessage(_Session session, IncomingRelayMessage message) async {
    final contact = session.contact;
    final ChatContent content;
    try {
      content = await MessageCodec.open(
        key: await session.key,
        sessionId: contact.sessionId,
        senderRole: contact.remoteRole,
        messageId: message.id,
        payload: message.payload,
      );
    } catch (_) {
      return;
    }

    // 回执不进聊天记录、不更新联系人时间、不回回执；照常确认让中继确认收下。
    if (content.type == ChatContent.typeReceipt) {
      await _handleReceipt(session, content);
      return;
    }

    if (content.type != ChatContent.typeText) return;

    final inserted = await LocalDatabase.insertMessageIfAbsent(StoredMessage(
      msgId: message.id,
      sessionId: contact.sessionId,
      senderPublicKey: contact.x25519PublicKeyBase64,
      ciphertext: message.payload,
      sequenceNumber: 0,
      timestamp: message.ts,
      direction: 'received',
      burnAfterRead: content.burn,
    ));
    if (!inserted) return;
    _plaintext[message.id] = content.body;
    await ContactStore.updateContactLastMessageTime(contact.deviceId, message.ts);

    // 只有新插入的消息才回 delivered 回执。先写 outbox 再发，重启也不会丢。
    final receipt = await _sealReceipt(
      contact,
      ChatContent.receipt(
        ChatContent.receiptDelivered,
        [message.id],
        sentAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await LocalDatabase.insertOutbox(
      msgId: receipt.msgId,
      sessionId: contact.sessionId,
      payload: receipt.payload,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (identical(_sessions[contact.sessionId], session)) _trySend(contact.sessionId, receipt);
    _notify(contact.sessionId);
  }

  /// 处理对方发来的回执。只动本会话里自己发出的消息；不认识的种类忽略。
  Future<void> _handleReceipt(_Session session, ChatContent content) async {
    final kind = content.receiptKind;
    if (kind != ChatContent.receiptDelivered && kind != ChatContent.receiptRead) return;
    final sessionId = session.contact.sessionId;
    final deleted = await LocalDatabase.applyReceipt(
      sessionId: sessionId,
      msgIds: content.ids,
      deleteBurned: kind == ChatContent.receiptRead,
    );
    deleted.forEach(_plaintext.remove);
    _notify(sessionId);
  }

  Future<void> _close(String sessionId) async {
    final session = _sessions.remove(sessionId);
    if (session == null) return;
    for (final subscription in session.subscriptions) {
      await subscription.cancel();
    }
    await session.client.stop();
    _notify(sessionId);
  }

  void _notify(String sessionId) {
    if (!_updates.isClosed) _updates.add(sessionId);
  }
}
