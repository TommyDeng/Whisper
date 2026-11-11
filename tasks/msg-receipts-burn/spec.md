# 端到端回执与阅后即焚

## 背景

Whisper 是 Flutter 桌面聊天客户端。两端各自连到一个 WebSocket 中继，中继只转发密文
（协议见 `docs/relay-protocol.md` 第一节，消息格式见 `docs/message-format.md`，请先读这两处）。

现在有两个问题要解决：

1. **送达回执会丢。** 发送方目前只靠中继的 `delivered` 帧知道对方收到了，而中继只在发送方在线时
   转发这个帧。发送方离线期间对方收到的消息，会永远停在“已发送”。
2. **没有阅后即焚。** 产品要求：阅后即焚的消息被对方读过之后，双方本机都删除。

做法：在加密的消息内容里增加一种“回执”内容，像普通消息一样经中继可靠送达（对方离线也会暂存）；
文本内容增加一个 `burn` 标记。中继不需要任何改动。

## 要读的文件

- `lib/messaging/message_codec.dart`：加解密。`ChatContent` 的新字段和构造函数**已经写好**
  （`burn`、`receiptKind`、`ids`、`ChatContent.receipt`、常量），但 `seal` / `open` 还不认识它们。
- `lib/messaging/messaging_service.dart`：消息服务。`sendText` 已有 `burn` 参数但没用上；
  `markRead`、`purgeBurned` 是 `throw UnimplementedError()`；`ChatMessage.burn` 字段已加但没填。
- `lib/storage/local_db.dart`：消息表的读写。`lib/storage/app_database.dart`：建表。
- `lib/relay/session_client.dart`（只读）：`send(id, payload)` 是可靠发送，`stored` 流给出中继已收下的 id，
  `errors` 流给出中继的错误。
- 验收测试（只读，行为有疑问时以测试为准）：
  `test/messaging/message_content_test.dart`、`test/messaging/receipts_burn_test.dart`。
  已有的 `test/messaging/messaging_service_test.dart`、`test/messaging/message_codec_test.dart`、
  `test/storage/app_database_test.dart` 也必须继续通过。

## 要求

保持现有公开接口不变（可以加成员）。不要加新的依赖。

### 一、消息内容格式（`message_codec.dart`）

明文 JSON 现在有两种：

```json
{"t":"text","body":"你好","ts":1700000000000,"burn":true}
{"t":"receipt","body":"","ts":1700000000000,"kind":"delivered","ids":["<消息 ID>", "..."]}
```

`seal`：

- 文本：`content.burn` 为 true 时写 `"burn":true`；为 false 时**不写**这个键（与旧格式逐字节兼容）。
- 回执（`type == ChatContent.typeReceipt`）：写 `body`（空串）、`ts`、`kind`、`ids`。以下情况抛
  `ArgumentError`：`receiptKind` 不是 `ChatContent.receiptDelivered` / `receiptRead`；`ids` 为空；
  `ids` 多于 `ChatContent.maxReceiptIds`（100）个；某个 id 超过 64 个字符。
- 其余（长度前缀、填充到 1024 的整数倍、加密、信封）不变。

`open`：

- `t`、`body`、`ts` 的检查不变。
- 有 `burn` 键时它必须是 JSON 布尔值，否则 `MessageCodecException('bad-content')`；没有则为 false。
  （`burn` 只对文本有意义，其它类型里出现时同样检查类型即可。）
- `t == "receipt"` 时：`kind` 必须是字符串；`ids` 必须是数组，1 到 100 个元素，每个都是不超过
  64 个字符的字符串。不满足一律 `MessageCodecException('bad-content')`。
  `kind` 的取值**不在这里限制**（不认识的种类照常解开，由上层忽略）。
- 不认识的 `t` 照常解开（现有行为），多余的键忽略。

### 二、待发回执表（`app_database.dart` / `local_db.dart`）

回执不存进 `messages` 表（它们不是聊天记录），但在中继确认收下之前必须熬得过重启。
新增一张表（名字用 `outbox`）：

```
outbox(msgId TEXT PRIMARY KEY, sessionId TEXT NOT NULL, payload TEXT NOT NULL, createdAt INTEGER NOT NULL)
```

- 在 `AppDatabase._ensureSchema` 里用 `CREATE TABLE IF NOT EXISTS` 创建，并把 `schemaVersion` 改为 4
  （这样旧库升级时会补上这张表）。
- 在 `LocalDatabase` 里加需要的读写方法（插入、按 id 删除、按会话查询并按 `createdAt, rowid` 升序、
  按会话删除）。方法名自定。
- `messages` 表已有 `burnAfterRead`、`read`、`readAt` 列，直接用。需要的话在 `LocalDatabase` 里加
  “限定会话和方向”的更新/删除方法，不要改现有方法的行为。

### 三、消息服务（`messaging_service.dart`）

**发回执的统一做法**（下面称“发回执”）：用 `MessageCodec.newMessageId()` 生成新 id，用会话密钥、
自己的角色（`contact.peerRole`）加密 `ChatContent.receipt(...)`，先写进 `outbox`，再在会话已连接
（`_sessions` 里有它）时调用 `client.send(id, payload)`。

1. **收到文本**（`_onMessage`）：
   - 落库时 `burnAfterRead` 取内容的 `burn`。
   - 只有**新插入**成功（不是重复投递）时，给对方发一条 `delivered` 回执，`ids` 就是这条消息的 id。
   - 解不开的消息、重复投递的消息不发回执。
2. **收到回执**：不落 `messages` 表、不更新联系人的最后消息时间、不回回执；照常正常返回让中继确认。
   - `delivered`：把 `ids` 里**属于本会话、方向为 `sent`** 的消息标为已送达。
   - `read`：同上标为已送达；其中 `burnAfterRead` 为真的直接从库里删除（同时清掉内存里的明文缓存
     `_plaintext`）。
   - 不属于本会话的 id、方向为 `received` 的 id 一律不动。
   - 不认识的 `kind`：忽略。
   - 处理完通知界面（`_notify(sessionId)`）。
3. **`sendText(contact, text, {burn})`**：`burn` 写进加密内容，并存到这条消息的 `burnAfterRead` 列。
4. **`messages(contact)`**：`ChatMessage.burn` 取自 `burnAfterRead` 列。
5. **`markRead(contact)`**：把该会话里方向为 `received`、`read == 0` 的消息标为已读
   （`read = 1`，`readAt` = 当前毫秒时间）。这些消息里 `burnAfterRead` 为真的，合成**一条** `read` 回执
   发给对方（超过 100 个就按 100 个一批拆成多条）。没有新读的焚毁消息就不发。
   会话当前没连接（不在 `_sessions` 里）时照样标记并写入 `outbox`，等下次 `attach` 时发出。
6. **`purgeBurned({sessionId})`**：删除方向为 `received`、`burnAfterRead` 为真且 `read` 为真的消息
   （给了 `sessionId` 就只删那个会话的），清掉它们的明文缓存，对每个受影响的会话 `_notify` 一次，
   返回删除条数。没读过的焚毁消息不删。
7. **可靠性**：
   - `client.stored` 发出某个 id 时，如果它在 `outbox` 里就删掉（现有的 `markRelayed` 调用保留）。
   - `client.errors` 里 `bad-id` / `bad-payload` / `too-large` 且带 id 时，如果它在 `outbox` 里就删掉
     （重发也不会成功）。
   - `attach(contact)`：在重发未被中继收下的聊天消息之后，把 `outbox` 里该会话的回执按顺序
     `client.send` 一遍（id 和 payload 都用库里存的原值，不要重新加密）。
   - `forget(contact)`：同时删除该会话的 `outbox` 记录。

### 四、文档（`docs/message-format.md`）

- “明文”一节补上 `burn` 字段和 `receipt` 内容的格式与校验规则。
- “接收方的处理”补上回执的处理规则。
- “已知限制”里关于送达回执依赖中继 `delivered` 帧的那一条，改写为现在的情况
  （回执是端到端加密的普通消息，发送方离线也能在上线后收到）。

### 其它

- 不要打印或记录 payload、消息 ID、密钥或明文。
- 不要改 `lib/relay/**`、`lib/contact/**`、任何测试文件。

## 验收命令

```
flutter analyze --no-pub --no-fatal-infos lib test
flutter test --no-pub test/messaging
flutter test --no-pub
```

三条都要通过，你改过的文件不能有新的 analyze 告警（现有的 24 条 info 可以不管）。
