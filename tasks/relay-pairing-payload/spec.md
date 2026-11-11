# 实现配对载荷的加解密 PairingPayload

## 背景

Whisper 是 Flutter 桌面聊天客户端。两台设备配对时，经中继交换两个加密载荷：加入者发给邀请人的
`pair-request`，邀请人批准后回给加入者的 `pair-response`。密码学构造写在 `docs/pairing-payload.md`，
**请先完整读它，并严格按它实现**（标签字符串、HKDF 的 salt/info 拼接顺序、AAD、JSON 字段名都必须一致，
验收测试会用独立实现交叉验证）。

`lib/pairing/pairing_payload.dart` 里已有公开接口和文档注释，`PairingPayload` 的五个静态方法都是
`throw UnimplementedError()`。你的任务是实现它们。**只改这一个文件。**

相关文件（只读）：

- `docs/pairing-payload.md`：构造与校验规则。
- `test/pairing/pairing_payload_test.dart`：验收测试。行为有疑问时以测试为准。
- `lib/e2ee/crypto.dart`：项目里已有的 `cryptography` 包用法（XChaCha20-Poly1305、X25519），可参考。

## 要求

- 保持现有公开接口不变（类名、字段、方法签名、`maxNameLength`）。可以加私有成员。
- 只用已有依赖：`package:cryptography`（`X25519`、`Hkdf(hmac: Hmac.sha256(), outputLength: 32)`、
  `Xchacha20.poly1305Aead()`）和 `dart:convert` / `dart:math` / `dart:typed_data`。不要加新依赖。
- 所有 base64url 输出都**不带 `=` 填充**；解码时要能接受无填充的输入。
- `newSessionId()`：`Random.secure()` 的 32 个随机字节，base64url 无填充（43 个字符）。
- `sealRequest`：每次调用生成新的临时 X25519 密钥对和新的随机 nonce。
- `openRequest` / `openResponse`：任何失败（base64 或 JSON 解析失败、字段缺失或类型/长度不对、`v != 1`、
  解密或 MAC 校验失败、明文内容不合法）都抛 `PairingPayloadException`，不能让 `FormatException`、
  `TypeError`、`SecretBoxAuthenticationError` 等其它异常漏出去。校验规则见文档“校验”一节。
- `openResponse` 返回的 `PairAcceptance.inviter.x25519PublicKey` 就是传入的 `inviterPublicKey`
  （响应明文里没有这个字段）。
- `sealRequest` / `sealResponse` 的输入不合法时抛 `ArgumentError`（在返回的 Future 里以错误完成即可）：
  公钥不是 32 字节、token 不是 16 字节、`name` 超过 `maxNameLength` 个字符、
  `sessionId` 不匹配 `^[A-Za-z0-9_-]{22,64}$`。
- 不要打印或记录任何密钥、明文或载荷；异常里也不要带这些内容。

## 验收命令

```
flutter analyze --no-pub --no-fatal-infos lib test
flutter test --no-pub test/pairing/pairing_payload_test.dart
flutter test --no-pub
```

三条都要通过。`pairing_payload.dart` 不能有新的 analyze 告警。
