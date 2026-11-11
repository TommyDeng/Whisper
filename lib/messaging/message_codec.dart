/// 聊天消息的端到端加密。格式见 docs/message-format.md。
///
/// 中继只看到这里产出的密文字符串；会话 ID、发送方身份和消息 ID 都绑定在
/// 附加数据里，中继把密文挪到别的会话、反射回发送方或换一个消息 ID 重放都会解密失败。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 一条消息的明文内容。
class ChatContent {
  const ChatContent({
    required this.type,
    required this.body,
    required this.sentAt,
    this.burn = false,
    this.receiptKind,
    this.ids = const [],
  });

  /// 文本消息。[burn] 为 true 表示阅后即焚。
  const ChatContent.text(this.body, {required this.sentAt, this.burn = false})
      : type = typeText,
        receiptKind = null,
        ids = const [];

  /// 回执：[kind] 是 [receiptDelivered] 或 [receiptRead]，[ids] 是被确认的消息 ID。
  const ChatContent.receipt(String kind, this.ids, {required this.sentAt})
      : type = typeReceipt,
        body = '',
        burn = false,
        receiptKind = kind;

  static const String typeText = 'text';
  static const String typeReceipt = 'receipt';

  static const String receiptDelivered = 'delivered';
  static const String receiptRead = 'read';

  /// 一条回执最多带多少个消息 ID。
  static const int maxReceiptIds = 100;

  /// 内容类型：[typeText] 或 [typeReceipt]；不认识的类型由接收方忽略。
  final String type;
  final String body;

  /// 发送方本地时间，unix 毫秒。
  final int sentAt;

  /// 仅文本：阅后即焚。
  final bool burn;

  /// 仅回执：种类。
  final String? receiptKind;

  /// 仅回执：被确认的消息 ID。
  final List<String> ids;
}

/// 密文无法解开或内容不合法。不携带任何密钥或明文。
class MessageCodecException implements Exception {
  const MessageCodecException(this.reason);

  final String reason;

  @override
  String toString() => 'MessageCodecException($reason)';
}

class MessageCodec {
  MessageCodec._();

  /// 文本消息正文的上限（UTF-8 字节）。
  static const int maxTextBytes = 16 * 1024;

  /// 明文填充到这个大小的整数倍，减少长度泄露。
  static const int paddingBlock = 1024;

  static final _aead = Xchacha20.poly1305Aead();
  static final _random = Random.secure();

  /// 新的消息 ID：16 字节随机数的 base64url（22 个字符）。
  static String newMessageId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return _encode(bytes);
  }

  /// 会话密钥：双方身份密钥做 X25519，再用 HKDF 绑定到会话 ID。
  static Future<SecretKey> deriveKey({
    required Uint8List myPrivateKey,
    required Uint8List peerPublicKey,
    required String sessionId,
  }) async {
    if (myPrivateKey.length != 32 || peerPublicKey.length != 32) {
      throw ArgumentError('密钥必须为 32 字节');
    }
    final x25519 = X25519();
    final shared = await x25519.sharedSecretKey(
      keyPair: await x25519.newKeyPairFromSeed(myPrivateKey),
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    if (sharedBytes.every((b) => b == 0)) {
      // 对方公钥是低阶点：共享密钥对任何人都一样，不能用
      throw const MessageCodecException('weak-key');
    }
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(sharedBytes),
      nonce: utf8.encode(sessionId),
      info: utf8.encode('whisper/session-key/v1'),
    );
  }

  /// 加密一条消息，返回交给中继的 payload。
  static Future<String> seal({
    required SecretKey key,
    required String sessionId,
    required String senderRole,
    required String messageId,
    required ChatContent content,
  }) async {
    if (content.type == ChatContent.typeText &&
        utf8.encode(content.body).length > maxTextBytes) {
      throw ArgumentError('消息过长');
    }
    final json = utf8.encode(jsonEncode({
      't': content.type,
      'body': content.body,
      'ts': content.sentAt,
    }));
    final padded = Uint8List(((4 + json.length + paddingBlock - 1) ~/ paddingBlock) * paddingBlock);
    ByteData.sublistView(padded).setUint32(0, json.length);
    padded.setRange(4, 4 + json.length, json);

    final box = await _aead.encrypt(
      padded,
      secretKey: key,
      nonce: _aead.newNonce(),
      aad: _aad(sessionId, senderRole, messageId),
    );
    return jsonEncode({
      'v': 1,
      'nonce': _encode(box.nonce),
      'ct': _encode(box.cipherText),
      'mac': _encode(box.mac.bytes),
    });
  }

  /// 解开一条消息。任何不对劲都抛 [MessageCodecException]。
  static Future<ChatContent> open({
    required SecretKey key,
    required String sessionId,
    required String senderRole,
    required String messageId,
    required String payload,
  }) async {
    final List<int> nonce, cipherText, mac;
    try {
      final envelope = jsonDecode(payload);
      if (envelope is! Map<String, dynamic> || envelope['v'] != 1) {
        throw const FormatException();
      }
      nonce = _decode(envelope['nonce']);
      cipherText = _decode(envelope['ct']);
      mac = _decode(envelope['mac']);
      if (nonce.length != 24 || mac.length != 16) throw const FormatException();
    } catch (_) {
      throw const MessageCodecException('malformed');
    }

    final List<int> padded;
    try {
      padded = await _aead.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: _aad(sessionId, senderRole, messageId),
      );
    } catch (_) {
      throw const MessageCodecException('decrypt-failed');
    }

    try {
      final bytes = Uint8List.fromList(padded);
      final length = ByteData.sublistView(bytes).getUint32(0);
      if (length > bytes.length - 4) throw const FormatException();
      final json = jsonDecode(utf8.decode(bytes.sublist(4, 4 + length)));
      if (json is! Map<String, dynamic>) throw const FormatException();
      final type = json['t'];
      final body = json['body'];
      final sentAt = json['ts'];
      if (type is! String || body is! String || sentAt is! int) throw const FormatException();
      return ChatContent(type: type, body: body, sentAt: sentAt);
    } catch (_) {
      throw const MessageCodecException('bad-content');
    }
  }

  static List<int> _aad(String sessionId, String senderRole, String messageId) =>
      utf8.encode('whisper/msg/v1\n$sessionId\n$senderRole\n$messageId');

  static String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  static List<int> _decode(Object? value) {
    if (value is! String) throw const FormatException();
    return base64Url.decode(base64Url.normalize(value));
  }
}
