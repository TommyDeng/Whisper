# 实现会话中继客户端 SessionClient

## 背景

Whisper 是 Flutter 桌面聊天客户端。两端通过一个 WebSocket 中继收发密文，协议见
`docs/relay-protocol.md` 第一节（会话中继 SessionDO）和开头的“通用规则”。请先读完这两部分。

`lib/relay/session_client.dart` 里已经有 `SessionClient` 的公开接口和文档注释，但所有成员都是
`throw UnimplementedError()`。你的任务是实现它。**只改这一个文件。**

相关文件（只读）：

- `lib/relay/relay_transport.dart`：`RelayConnection`、`RelayConnector`、`RelayError`。
- `test/relay/fake_relay.dart`：测试用的假连接。
- `test/relay/session_client_test.dart`：验收测试。行为有疑问时以测试为准。

## 要求

保持 `session_client.dart` 现有的公开接口不变（类名、构造参数、成员签名、`SessionLinkState`、
`IncomingRelayMessage`、`RelayMessageHandler`）。可以加私有成员。不要加新的依赖。

### 连接与状态

- `start()`：状态变为 `connecting`，调用 `connector(uri)`。`uri` 由 `baseUri` 得到：保留 scheme、
  host、port，path 为 `/session/<sessionId>`，查询参数只有 `peer=<peer>`。
- 连接建立后**不发送任何帧**，直到收到 `{"type":"welcome",...}`。收到后状态变为 `connected`，
  `peerOnline` 取 welcome 里的 `peerOnline`，然后把待确认的消息按顺序发出。
- `peer-online` / `peer-offline` 更新 `peerOnline`。连接结束或 `stop()` 后 `peerOnline` 为 false。
- `states`、`peerOnlineChanges` 是广播流，只在值确实改变时发出。
- 已经 start 过（正在连接、已连接或正在等待重连）时再调用 `start()` 无效果。

### 发送

- `send(id, payload)`：把 `(id, payload)` 追加到待确认队列；已连接则立即发
  `{"type":"msg","id":id,"payload":payload}`（不要带其它字段）。同一个 id 已在队列里则整个调用无效果。
- 收到 `{"type":"stored","id"}`：从队列移除该 id，并在 `stored` 流发出。
- 每次重新连接并收到 welcome 后，按原顺序重发队列里的全部消息。
- `sendEphemeral(id, payload)`：未连接返回 false，不发送、不排队；已连接发
  `{"type":"msg","id":id,"payload":payload,"ephemeral":true}` 并返回 true。
- `delivered`、`dropped` 帧分别在对应的流发出 id。
- `{"type":"error","error":码,"id":可选}`：在 `errors` 流发出 `RelayError(码, id)`。码为 `bad-id`、
  `bad-payload`、`too-large` 且带 id 时，把该 id 从待确认队列移除（重发也不会成功）；其它错误
  （如 `queue-full`、`rate-limited`）不动队列。错误不影响连接。

### 接收

- 收到 `{"type":"msg","id":字符串,"payload":字符串,"ts":整数}`：调用 `onMessage`。它正常完成后，
  如果收到这条消息的那条连接仍是当前连接且未结束，就发 `{"type":"ack","id":id}`；它抛异常则不 ack。
  任何情况下都不能让异常逃出去（不能出现未处理的异步错误）。
- 消息严格按到达顺序逐条处理：前一条的 `onMessage` 没完成（或没抛出）之前不开始下一条。
- 不是合法 JSON、不是 JSON 对象、`type` 不认识、字段类型不对的帧一律忽略，不报错、不断开。

### 重连

- 连接结束（`frames` 流 done）或 `connector` 抛异常，都算一次失败：状态变为 `disconnected`，
  第 n 次连续失败后等 `backoff[n-1]`（超出长度用最后一项）再重新连接，重连时状态回到 `connecting`。
  收到 welcome 时连续失败次数清零。
- 例外：连接结束且 `closeCode == 4001` 时不再重连，在 `errors` 流发出 `RelayError('replaced')`，
  状态保持 `disconnected`，之后可以再调用 `start()`。
- 心跳：处于 `connected` 时每隔 `pingInterval` 发 `{"type":"ping"}`。发出后 `pongTimeout` 内没有收到
  `{"type":"pong"}`，就主动 `close()` 这条连接，并按一次失败处理（走上面的重连）。
  连接结束时取消心跳相关的定时器。

### 停止

- `stop()`：关闭当前连接（包括正在建立、稍后才返回的连接——拿到后立即关闭），取消所有定时器，
  状态变为 `disconnected`，不再重连。待确认队列保留。之后可以再次 `start()`，连上后重发队列。
- `stop()` 之后，旧连接上迟到的事件（帧、done、`onMessage` 完成）不得再改变状态、发帧或触发重连。

### 其它

- 不要打印或记录 payload、消息 ID。
- `pendingIds` 返回副本，不要把内部列表暴露出去。

## 验收命令

```
flutter analyze --no-pub --no-fatal-infos lib test
flutter test --no-pub test/relay/session_client_test.dart
flutter test --no-pub
```

三条都要通过。`session_client.dart` 不能有新的 analyze 告警。
