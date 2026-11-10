# 聊天消息格式

会话中继（`docs/relay-protocol.md` 第一节）里 `msg.payload` 的内容。实现在 `lib/messaging/message_codec.dart`。

## 会话密钥

```
shared = X25519(自己的身份私钥, 对方的身份公钥)
key    = HKDF-SHA256(ikm = shared, salt = utf8(sessionId), info = utf8("whisper/session-key/v1"))，32 字节
```

`shared` 全为 0（对方公钥是低阶点）时拒绝使用。双方身份公钥在配对时交换，见 `docs/pairing-payload.md`。

密钥是静态的：目前没有前向保密，身份私钥泄露后，录下来的历史密文可以被解开。棘轮留待以后。

## 密文

`payload` 是一个 JSON 字符串，各字段为不带填充的 base64url：

```json
{"v":1,"nonce":"<24 字节>","ct":"<密文>","mac":"<16 字节>"}
```

- 算法：XChaCha20-Poly1305，每条消息随机 nonce。
- 附加数据：`utf8("whisper/msg/v1\n" + sessionId + "\n" + 发送方角色 + "\n" + 消息 ID)`。发送方角色是 `a`（当初的邀请人）或 `b`（加入者），消息 ID 就是中继帧里的 `id`。这样中继无法把密文挪到别的会话、反射回发送方，或换一个 ID 重放成一条“新”消息。
- 消息 ID：发送方生成的 16 字节随机数的 base64url（22 个字符）。接收方按它去重。

## 明文

```
4 字节大端长度 N | N 字节 UTF-8 JSON | 0 填充到 1024 字节的整数倍
```

JSON：

```json
{"t":"text","body":"你好","ts":1700000000000}
```

- `t`：内容类型。目前只有 `text`；接收方遇到不认识的类型时确认收到并忽略。
- `body`：正文，UTF-8 不超过 16 KiB。
- `ts`：发送方本地时间，unix 毫秒。

## 接收方的处理

解不开或内容不合法的消息直接丢弃，但仍向中继确认（`ack`），否则中继每次重连都会重投。本地保存的是收到的密文原文，显示时再解密。

## 已知限制

- 送达回执依赖中继的 `delivered` 帧，而它只在发送方在线时转发。发送方离线期间对方收到的消息，发送方这边会一直停在“已发送”。
