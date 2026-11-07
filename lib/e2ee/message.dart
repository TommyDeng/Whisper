/// 耳语 E2EE 聊天消息格式。
///
/// 每条聊天消息包含：
/// - msgId：消息唯一标识（用于去重和 ACK）
/// - sessionId：会话 ID（与 DO 房间名相同）
/// - senderPublicKey：发送方 X25519 公钥（base64）
/// - ciphertext：XChaCha20-Poly1305 加密后的消息内容
/// - sequenceNumber：消息序号（用于去重和顺序）
/// - timestamp：发送时间戳（Unix 毫秒）
/// - delivered：是否已送达（对方 ACK 后置 true）
/// - read：是否已读（阅后即焚时使用）
/// - burnAfterRead：是否开启阅后即焚

/// 本地存储的加密聊天消息
class StoredMessage {
  const StoredMessage({
    required this.msgId,
    required this.sessionId,
    required this.senderPublicKey,
    required this.ciphertext,
    required this.sequenceNumber,
    required this.timestamp,
    required this.direction, // 'sent' 或 'received'
    this.delivered = false,
    this.read = false,
    this.burnAfterRead = false,
    this.readAt,
  });

  final String msgId;
  final String sessionId;
  final String senderPublicKey;
  final String ciphertext; // JSON 编码的 EncryptedMessage
  final int sequenceNumber;
  final int timestamp;
  final String direction;
  final bool delivered;
  final bool read;
  final bool burnAfterRead;
  final int? readAt;

  /// 转换为数据库 Map
  Map<String, dynamic> toMap() => {
    'msgId': msgId,
    'sessionId': sessionId,
    'senderPublicKey': senderPublicKey,
    'ciphertext': ciphertext,
    'sequenceNumber': sequenceNumber,
    'timestamp': timestamp,
    'direction': direction,
    'delivered': delivered ? 1 : 0,
    'read': read ? 1 : 0,
    'burnAfterRead': burnAfterRead ? 1 : 0,
    'readAt': readAt,
  };

  /// 从数据库 Map 反序列化
  static StoredMessage fromMap(Map<String, dynamic> map) => StoredMessage(
    msgId: map['msgId'] as String,
    sessionId: map['sessionId'] as String,
    senderPublicKey: map['senderPublicKey'] as String,
    ciphertext: map['ciphertext'] as String,
    sequenceNumber: map['sequenceNumber'] as int,
    timestamp: map['timestamp'] as int,
    direction: map['direction'] as String,
    delivered: (map['delivered'] as int) == 1,
    read: (map['read'] as int) == 1,
    burnAfterRead: (map['burnAfterRead'] as int) == 1,
    readAt: map['readAt'] as int?,
  );
}

/// 出站消息（等待发送）
class OutgoingMessage {
  const OutgoingMessage({
    required this.msgId,
    required this.sessionId,
    required this.sequenceNumber,
    required this.plaintext,
    required this.burnAfterRead,
    required this.timestamp,
  });

  final String msgId;
  final String sessionId;
  final int sequenceNumber;
  final String plaintext;
  final bool burnAfterRead;
  final int timestamp;
}
