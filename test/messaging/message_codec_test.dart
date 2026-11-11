import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/identity/identity_store.dart';
import 'package:whisper/messaging/message_codec.dart';

void main() {
  late IdentityKeyPair alice;
  late IdentityKeyPair bob;
  late SecretKey aliceKey;
  late SecretKey bobKey;
  const sessionId = 'session-0000000000000000000001';

  setUp(() async {
    alice = await generateIdentityKeyPair();
    bob = await generateIdentityKeyPair();
    aliceKey = await MessageCodec.deriveKey(
      myPrivateKey: alice.x25519PrivateKey,
      peerPublicKey: bob.x25519PublicKey,
      sessionId: sessionId,
    );
    bobKey = await MessageCodec.deriveKey(
      myPrivateKey: bob.x25519PrivateKey,
      peerPublicKey: alice.x25519PublicKey,
      sessionId: sessionId,
    );
  });

  Future<String> seal(String body, {String id = 'm1', String role = 'a'}) => MessageCodec.seal(
        key: aliceKey,
        sessionId: sessionId,
        senderRole: role,
        messageId: id,
        content: ChatContent.text(body, sentAt: 1234),
      );

  Future<ChatContent> open(
    String payload, {
    SecretKey? key,
    String session = sessionId,
    String role = 'a',
    String id = 'm1',
  }) =>
      MessageCodec.open(
        key: key ?? bobKey,
        sessionId: session,
        senderRole: role,
        messageId: id,
        payload: payload,
      );

  Matcher fails(String reason) =>
      throwsA(isA<MessageCodecException>().having((e) => e.reason, 'reason', reason));

  test('双方算出同一把会话密钥；会话 ID 不同则密钥不同', () async {
    expect(await aliceKey.extractBytes(), await bobKey.extractBytes());
    final other = await MessageCodec.deriveKey(
      myPrivateKey: alice.x25519PrivateKey,
      peerPublicKey: bob.x25519PublicKey,
      sessionId: 'session-0000000000000000000002',
    );
    expect(await other.extractBytes(), isNot(await aliceKey.extractBytes()));
  });

  test('低阶公钥被拒绝', () async {
    await expectLater(
      MessageCodec.deriveKey(
        myPrivateKey: alice.x25519PrivateKey,
        peerPublicKey: Uint8List(32),
        sessionId: sessionId,
      ),
      fails('weak-key'),
    );
  });

  test('加密后对方能解开，内容一致', () async {
    for (final body in ['你好，世界 👋', '', 'a' * 5000]) {
      final content = await open(await seal(body));
      expect(content.type, ChatContent.typeText);
      expect(content.body, body);
      expect(content.sentAt, 1234);
    }
  });

  test('密文里看不出明文和长度', () async {
    // 明文选一个 base64url 字符集之外的串，避免随机密文碰巧包含它
    final short = await seal('hi there!');
    final longer = await seal('这是一条长一些、但仍在同一个填充块里的消息');
    expect(short.contains('hi there!'), isFalse);
    expect(short.length, longer.length);
    final envelope = jsonDecode(short) as Map<String, dynamic>;
    expect(envelope.keys, unorderedEquals(['v', 'nonce', 'ct', 'mac']));
    expect(base64Url.decode(base64Url.normalize(envelope['ct'] as String)), hasLength(1024));
    expect(await seal('hi there!'), isNot(short), reason: '每次的 nonce 不同');
  });

  test('超长文本拒绝加密', () async {
    await expectLater(seal('a' * (MessageCodec.maxTextBytes + 1)), throwsArgumentError);
    await seal('a' * MessageCodec.maxTextBytes);
  });

  test('换会话、换发送方、换消息 ID、换密钥都解不开', () async {
    final payload = await seal('hi');
    await expectLater(open(payload, session: 'session-0000000000000000000002'), fails('decrypt-failed'));
    await expectLater(open(payload, role: 'b'), fails('decrypt-failed'), reason: '反射回发送方');
    await expectLater(open(payload, id: 'm2'), fails('decrypt-failed'), reason: '换 ID 重放');
    final eve = await generateIdentityKeyPair();
    final eveKey = await MessageCodec.deriveKey(
      myPrivateKey: eve.x25519PrivateKey,
      peerPublicKey: alice.x25519PublicKey,
      sessionId: sessionId,
    );
    await expectLater(open(payload, key: eveKey), fails('decrypt-failed'));
  });

  test('被改动或畸形的密文', () async {
    final envelope = jsonDecode(await seal('hi')) as Map<String, dynamic>;
    final ct = base64Url.decode(base64Url.normalize(envelope['ct'] as String));
    ct[0] ^= 1;
    await expectLater(
      open(jsonEncode({...envelope, 'ct': base64Url.encode(ct)})),
      fails('decrypt-failed'),
    );
    await expectLater(open('not json'), fails('malformed'));
    await expectLater(open(jsonEncode({...envelope, 'v': 2})), fails('malformed'));
    await expectLater(open(jsonEncode({...envelope, 'nonce': 'AAAA'})), fails('malformed'));
    await expectLater(open(jsonEncode({...envelope, 'mac': 5})), fails('malformed'));
  });

  test('消息 ID 是 22 个 URL 安全字符，且不重复', () {
    final ids = {for (var i = 0; i < 100; i++) MessageCodec.newMessageId()};
    expect(ids, hasLength(100));
    expect(ids.every(RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch), isTrue);
  });
}
