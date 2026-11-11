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

  /// 用会话密钥把一条回执加密、写入 outbox，会话已连接时立即发出。
  Future<void> _sendReceipt(_Session session, ChatContent receipt) async {
    final id = MessageCodec.newMessageId();
    final payload = await MessageCodec.seal(
      key: await session.key,
      sessionId: session.contact.sessionId,
      senderRole: session.contact.peerRole,
      messageId: id,
      content: receipt,
    );
    await LocalDatabase.insertOutbox(
      msgId: id,
      sessionId: session.contact.sessionId,
      payload: payload,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (_sessions[session.contact.sessionId] == session) {
      session.client.send(id, payload);
    }
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
    final session = _sessions[contact.sessionId];
    final ids = await LocalDatabase.markSessionRead(contact.sessionId);
    if (ids.isEmpty) return;

    // 其中 burnAfterRead 为真的消息要发 read 回执；只发给本会话的、方向为 received 的消息
    final burnedIds = <String>[];
    for (final id in ids) {
      final message = await LocalDatabase.getMessage(id);
      if (message != null && message.burnAfterRead) burnedIds.add(id);
    }
    if (burnedIds.isEmpty) return;

    // 合成一条 read 回执，超过 100 个按 100 个一批拆成多条
    for (var i = 0; i < burnedIds.length; i += ChatContent.maxReceiptIds) {
      final batch = burnedIds.sublist(
        i,
        i + ChatContent.maxReceiptIds > burnedIds.length
            ? burnedIds.length
            : i + ChatContent.maxReceiptIds,
      );
      if (session != null) {
        await _sendReceipt(
          session,
          ChatContent.receipt(ChatContent.receiptRead, batch, sentAt: DateTime.now().millisecondsSinceEpoch),
        );
      } else {
        // 会话未连接：回执已经在 markSessionRead 之前写进库？不是。这里需要先写 outbox。
        // 统一走 _sendReceipt 会需要 session；会话没连接时先落 outbox，attach 时重发。
        final receiptId = MessageCodec.newMessageId();
        // 先加密出 payload 再写出box；需要密钥。
        final key = await (_deriveKey(contact));
        final payload = await MessageCodec.seal(
          key: key,
          sessionId: contact.sessionId,
          senderRole: contact.peerRole,
          messageId: receiptId,
          content: ChatContent.receipt(
            ChatContent.receiptRead,
            batch,
            sentAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await LocalDatabase.insertOutbox(
          msgId: receiptId,
          sessionId: contact.sessionId,
          payload: payload,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
    }
    _notify(contact.sessionId);
  }

  /// 删除已读的、收到的阅后即焚消息（离开聊天界面和启动时调用）。
  /// [sessionId] 为 null 时处理所有会话。返回删除的条数。
  Future<int> purgeBurned({String? sessionId}) async {
    final affected = await LocalDatabase.deleteReadBurned(sessionId: sessionId);
    final sessionsToNotify = <String>{};
    for (final row in affected) {
      _plaintext.remove(row['msgId'] as String);
      if (row['sessionId'] is String) {
        sessionsToNotify.add(row['sessionId'] as String);
      }
    }
    for (final sid in sessionsToNotify) {
      _notify(sid);
    }
    return affected.length;
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

    // 只有新插入的消息才回 delivered 回执，ids 就是这条消息的 id
    await _sendReceipt(
      session,
      ChatContent.receipt(
        ChatContent.receiptDelivered,
        [message.id],
        sentAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _notify(contact.sessionId);
  }

  /// 处理收到的回执：delivered/read 把 ids 里属于本会话、方向为 sent 的消息
  /// 标为已送达；read 里 burnAfterRead 为真的直接从库里删除（并清内存明文缓存）。
  Future<void> _handleReceipt(_Session session, ChatContent content) async {
    final contact = session.contact;
    final ids = content.ids;
    if (ids.isEmpty) return;

    final db = await LocalDatabase.database;

    for (final id in ids) {
      final message = await LocalDatabase.getMessage(id);
      if (message == null) continue;
      if (message.sessionId != contact.sessionId) continue;
      if (message.direction != 'sent') continue;
      await db.update(
        'messages',
        {'delivered': 1},
        where: 'msgId = ?',
        whereArgs: [id],
      );
    }

    if (content.receiptKind == ChatContent.receiptRead) {
      final burned = <String>[];
      for (final id in ids) {
        final message = await LocalDatabase.getMessage(id);
        if (message == null) continue;
        if (message.sessionId != contact.sessionId) continue;
        if (message.direction != 'sent') continue;
        if (message.burnAfterRead) burned.add(id);
      }
      if (burned.isNotEmpty) {
        await db.delete(
          'messages',
          where: 'msgId IN (${List.generate(burned.length, (_) => '?').join(',')})',
          whereArgs: burned,
        );
        for (final id in burned) {
          _plaintext.remove(id);
        }
      }
    }

    _notify(contact.sessionId);
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
