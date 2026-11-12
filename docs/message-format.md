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

JSON 文本消息：

```json
{"t":"text","body":"你好","ts":1700000000000}
{"t":"text","body":"你好","ts":1700000000000,"burn":true}
```

- `t`：内容类型。目前有 `text`、`file` 和 `receipt`；`t` 为 `call` 的内容是通话信令，只作为临时消息
  发送，见 `docs/call-signaling.md`。接收方遇到不认识的类型时确认收到并忽略。
- `body`：正文，UTF-8 不超过 16 KiB。
- `ts`：发送方本地时间，unix 毫秒。
- `burn`：仅文本可选。为 `true` 时表示阅后即焚；缺省或不存在时为 `false`。

JSON 文件消息（和文本消息一样落库、去重、回 `delivered` 回执）：

```json
{"t":"file","body":"<FileOffer 的 JSON 字符串>","ts":1700000000000}
```

- `body`：文件的描述（文件 ID、文件名、大小、密钥、哈希），格式见 `docs/file-relay.md` 的“文件消息”，不超过 2048 字节。文件内容本身不在消息里，另经文件中转接口传输。
- `body` 解不出合格描述的文件消息直接丢弃。文件消息不支持 `burn`。

JSON 回执（和文本消息一样经中继可靠送达）：

```json
{"t":"receipt","body":"","ts":1700000000000,"kind":"delivered","ids":["<消息 ID>", "..."]}
```

- `t`：固定为 `receipt`。
- `body`：固定为空串。
- `ts`：发送方本地时间，unix 毫秒。
- `kind`：回执种类，`delivered`（已送达）或 `read`（已读）；上层不认识的种类照常忽略。
- `ids`：被确认的消息 ID 列表，1 到 100 个，每个不超过 64 个字符。

## 接收方的处理

解不开或内容不合法的消息直接丢弃，但仍向中继确认（`ack`），否则中继每次重连都会重投。本地保存的是收到的密文原文，显示时再解密。

回执的处理：

- `delivered`：把 `ids` 里属于本会话、方向为 `sent` 的消息标为已送达。
- `read`：同上标为已送达；其中 `burnAfterRead` 为真的消息直接从本地删除（连同内存里的明文缓存）。
- 不属于本会话的 id、方向为 `received` 的 id 一律不动。
- 不认识的 `kind` 忽略。
- 回执不写入 `messages` 表、不更新联系人最后消息时间、不回回执。

## 已知限制

- 回执是端到端加密的普通消息，和聊天消息一样经中继可靠送达（对方离线时会暂存），发送方离线期间对方发出的回执会在发送方上线后被重发，因此不再依赖中继的 `delivered` 帧。
