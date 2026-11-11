// 消息内容的扩展：阅后即焚标记和回执。格式见 docs/message-format.md。
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/identity/identity_store.dart';
import 'package:whisper/messaging/message_codec.dart';

const _sessionId = 'session-0000000000000000000001';
const _id = 'AAAAAAAAAAAAAAAAAAAAAA';

/// 按 docs/message-format.md 手工封一条明文为 [json] 的消息，用来构造编码器不会产出的内容。
Future<String> _sealRaw(SecretKey key, Map<String, Object?> json) async {
  final bytes = utf8.encode(jsonEncode(json));
  final padded = Uint8List(((4 + bytes.length + 1023) ~/ 1024) * 1024);
  ByteData.sublistView(padded).setUint32(0, bytes.length);
  padded.setRange(4, 4 + bytes.length, bytes);
  final aead = Xchacha20.poly1305Aead();
  final box = await aead.encrypt(
    padded,
    secretKey: key,
    nonce: aead.newNonce(),
    aad: utf8.encode('whisper/msg/v1\n$_sessionId\na\n$_id'),
  );
  String enc(List<int> b) => base64Url.encode(b).replaceAll('=', '');
  return jsonEncode({'v': 1, 'nonce': enc(box.nonce), 'ct': enc(box.cipherText), 'mac': enc(box.mac.bytes)});
}

void main() {
  late SecretKey key;

  setUp(() async {
    final alice = await generateIdentityKeyPair();
    final bob = await generateIdentityKeyPair();
    key = await MessageCodec.deriveKey(
      myPrivateKey: alice.x25519PrivateKey,
      peerPublicKey: bob.x25519PublicKey,
      sessionId: _sessionId,
    );
  });

  Future<ChatContent> roundTrip(ChatContent content) async => MessageCodec.open(
        key: key,
        sessionId: _sessionId,
        senderRole: 'a',
        messageId: _id,
        payload: await MessageCodec.seal(
          key: key,
          sessionId: _sessionId,
          senderRole: 'a',
          messageId: _id,
          content: content,
        ),
      );

  Future<ChatContent> openRaw(Map<String, Object?> json) async => MessageCodec.open(
        key: key,
        sessionId: _sessionId,
        senderRole: 'a',
        messageId: _id,
        payload: await _sealRaw(key, json),
      );

  Matcher badContent() => throwsA(
        isA<MessageCodecException>().having((e) => e.reason, 'reason', 'bad-content'),
      );

  test('文本的阅后即焚标记能往返，默认是关', () async {
    final plain = await roundTrip(const ChatContent.text('hi there!', sentAt: 7));
    expect(plain.type, ChatContent.typeText);
    expect(plain.burn, isFalse);
    expect(plain.ids, isEmpty);
    expect(plain.receiptKind, isNull);

    final burn = await roundTrip(const ChatContent.text('hi there!', sentAt: 7, burn: true));
    expect(burn.body, 'hi there!');
    expect(burn.sentAt, 7);
    expect(burn.burn, isTrue);
  });

  test('没有 burn 字段的旧格式文本照常解开', () async {
    final content = await openRaw({'t': 'text', 'body': 'old', 'ts': 3});
    expect(content.body, 'old');
    expect(content.burn, isFalse);
  });

  test('回执能往返', () async {
    for (final kind in [ChatContent.receiptDelivered, ChatContent.receiptRead]) {
      final content = await roundTrip(ChatContent.receipt(kind, const ['id-1', 'id-2'], sentAt: 9));
      expect(content.type, ChatContent.typeReceipt);
      expect(content.receiptKind, kind);
      expect(content.ids, ['id-1', 'id-2']);
      expect(content.sentAt, 9);
      expect(content.body, '');
      expect(content.burn, isFalse);
    }
  });

  test('回执的密文和文本一样填充到 1024 的整数倍', () async {
    final payload = await MessageCodec.seal(
      key: key,
      sessionId: _sessionId,
      senderRole: 'a',
      messageId: _id,
      content: ChatContent.receipt(ChatContent.receiptDelivered, const ['id-1'], sentAt: 9),
    );
    final ct = (jsonDecode(payload) as Map<String, dynamic>)['ct'] as String;
    expect(base64Url.decode(base64Url.normalize(ct)).length, 1024);
  });

  test('seal 拒绝不合法的回执', () async {
    Future<String> seal(ChatContent content) => MessageCodec.seal(
          key: key,
          sessionId: _sessionId,
          senderRole: 'a',
          messageId: _id,
          content: content,
        );
    final tooMany = List.generate(ChatContent.maxReceiptIds + 1, (i) => 'id-$i');
    await expectLater(
      seal(ChatContent.receipt(ChatContent.receiptRead, tooMany, sentAt: 1)),
      throwsArgumentError,
    );
    await expectLater(
      seal(ChatContent.receipt('seen', const ['id-1'], sentAt: 1)),
      throwsArgumentError,
    );
    await expectLater(
      seal(ChatContent.receipt(ChatContent.receiptRead, const [], sentAt: 1)),
      throwsArgumentError,
    );
    // 上限以内可以
    final max = List.generate(ChatContent.maxReceiptIds, (i) => 'id-$i');
    expect((await roundTrip(ChatContent.receipt(ChatContent.receiptRead, max, sentAt: 1))).ids, max);
  });

  test('open 拒绝字段不对的内容', () async {
    await expectLater(openRaw({'t': 'text', 'body': 'x', 'ts': 1, 'burn': 'yes'}), badContent());
    await expectLater(openRaw({'t': 'text', 'body': 'x', 'ts': 1, 'burn': 1}), badContent());

    Map<String, Object?> receipt(Object? kind, Object? ids) =>
        {'t': 'receipt', 'body': '', 'ts': 1, 'kind': kind, 'ids': ids};
    await expectLater(openRaw({'t': 'receipt', 'body': '', 'ts': 1}), badContent());
    await expectLater(openRaw(receipt('delivered', 'id-1')), badContent());
    await expectLater(openRaw(receipt('delivered', ['id-1', 2])), badContent());
    await expectLater(openRaw(receipt('delivered', <String>[])), badContent());
    await expectLater(openRaw(receipt(null, ['id-1'])), badContent());
    await expectLater(openRaw(receipt(5, ['id-1'])), badContent());
    await expectLater(
      openRaw(receipt('delivered', List.generate(ChatContent.maxReceiptIds + 1, (i) => 'id-$i'))),
      badContent(),
    );
    await expectLater(openRaw(receipt('delivered', ['x' * 65])), badContent());
  });

  test('不认识的回执种类和内容类型能解开，由上层忽略', () async {
    final receipt = await openRaw({'t': 'receipt', 'body': '', 'ts': 1, 'kind': 'seen', 'ids': ['id-1']});
    expect(receipt.receiptKind, 'seen');
    final future = await openRaw({'t': 'future', 'body': 'x', 'ts': 1, 'extra': 1});
    expect(future.type, 'future');
  });
}
