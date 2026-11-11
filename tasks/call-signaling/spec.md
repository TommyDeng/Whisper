# 通话信令：加密的临时消息通道 + 通话状态机

## 背景

Whisper 是 Flutter 桌面聊天客户端。两端各自连到一个 WebSocket 中继，中继只转发密文
（协议见 `docs/relay-protocol.md` 第一节，消息格式见 `docs/message-format.md`）。

现在要把语音通话接进来。通话的信令（SDP offer/answer、ICE 候选、响铃、挂断）必须端到端加密，
走现有的会话中继，作为**临时消息**发送：中继不暂存，对方在线就转发，不在线就回一个
`{"type":"dropped","id"}`。客户端一侧 `SessionClient.sendEphemeral(id, payload)`（未连接时返回 false）
和 `SessionClient.dropped` 流已经有了。

这个任务做两件事，都不碰真正的 WebRTC 和界面：

1. `MessagingService` 增加收发通话信令的三个成员（现在是 `throw UnimplementedError()`）。
2. 实现 `CallService` 状态机（`lib/call/call_service.dart`，类型和方法签名已写好，方法体是
   `throw UnimplementedError()`）。

## 要读的文件

- `lib/call/call_signal.dart`（只读，已完成）：信令内容 `CallSignal` 的编解码。
- `lib/call/call_service.dart`：`CallTransport`、`CallMedia`、`CallSnapshot`、`CallService` 的定义和文档注释。
  **公开的类型、成员和签名都不要改**，只填实现（可以加私有成员）。
- `lib/call/call_transport.dart`（只读）：把 `MessagingService` 接成 `CallTransport` 的适配器。
- `lib/messaging/messaging_service.dart`：`callSignals`、`signalDropped`、`sendCallSignal` 三个占位成员；
  `_onMessage` 是收消息的入口，`attach` 里订阅 `SessionClient` 的各个流。
- `lib/messaging/message_codec.dart`（只读）：`ChatContent.call(body, sentAt:)`、`ChatContent.typeCall`、
  `MessageCodec.maxSignalBytes` 已加好，`seal` 会在信令超长时抛 `ArgumentError`。
- `lib/relay/session_client.dart`（只读）。
- 验收测试（只读，行为有疑问时以测试为准）：
  `test/call/call_service_test.dart`、`test/messaging/call_signals_test.dart`、`test/call/call_signal_test.dart`。

## 要求

不要加新的依赖。不要打印或记录 payload、消息 ID、SDP、候选、密钥或明文。

### 一、`MessagingService`

- `callSignals`、`signalDropped`：两个广播流，服务一构造出来就能监听（在 `start` 之前、可以多次监听）；
  `dispose` 时关闭。`reset()` 不关闭它们。
- `sendCallSignal(contact, body)`：
  - `_sessions` 里没有这个联系人的会话 → 返回 null。
  - 用 `MessageCodec.newMessageId()` 生成 id，用会话密钥和自己的角色（`contact.peerRole`）加密
    `ChatContent.call(body, sentAt: 当前毫秒)`，调用 `client.sendEphemeral(id, payload)`；
    它返回 true 则返回 id，返回 false 则返回 null。
  - 加密期间会话可能已被替换或关闭：发送前像 `sendText` 那样用 `identical` 检查，不是同一个会话就返回 null。
  - 不落库、不写 `outbox`、不调 `_notify`。超长时 `seal` 抛出的 `ArgumentError` 原样抛给调用方。
- 收到 `ChatContent.typeCall` 的内容（在 `_onMessage` 里，解密成功之后）：把
  `(contact: session.contact, body: content.body)` 发到 `callSignals`，然后正常返回（让中继确认）。
  不落库、不回回执、不更新联系人最后消息时间、不调 `_notify`。
- `attach` 里订阅 `client.dropped`，每个 id 以 `(sessionId: 该会话 ID, id: id)` 发到 `signalDropped`。

### 二、`CallService`

一次只有一通通话。状态用 `CallSnapshot` 表示，`snapshot` 取当前值，每次变化往 `changes`（广播流）发一个新的。
构造时就开始监听 `transport.incoming` 和 `transport.dropped`。

名词：**结束**一通通话 = 取消所有定时器，关闭媒体（如果已创建，`media.close()`），取消对媒体流的订阅，
把 callId 记入“已结束”集合（只需保留最近 64 个），状态变为
`phase: ended, endReason: <原因>`，保留 `contact`、`callId`、`isOutgoing`。
结束之后，这通通话迟到的信令和媒体事件一律不再有任何效果。

信令用 `CallSignal.xxx(...).encode()` 生成、`transport.send(contact, body)` 发出；
收到的用 `CallSignal.decode(body)` 解析，返回 null 的直接忽略。
除了 offer，其它信令只有在 **发送方的 `sessionId` 等于当前通话对方的 `sessionId`、且 `callId` 等于当前通话的
`callId`、且当前不是 idle / ended** 时才处理，否则忽略。

**呼出 `start(contact)`**

1. 当前是 outgoing / incoming / connecting / active → 抛 `StateError`。idle 或 ended 都可以开始。
2. 生成 callId（`MessageCodec.newMessageId()`），状态变为 `outgoing`（`isOutgoing: true`，`muted: false`，
   其它字段清空）。
3. `createMedia()`，**先订阅** `media.candidates` 和 `media.states`，再 `await media.createOffer()`。
   抛异常 → 以 `failed` 结束，不发任何信令，`start` 正常返回。
4. 发 offer。`transport.send` 返回 null → 以 `offline` 结束。否则记住返回的消息 ID。
5. 启动响铃定时器 `ringTimeout`：到时仍是 outgoing → 发 `end(hangup)`，以 `timeout` 结束。
6. `start` 在 offer 发出（或通话已结束）后完成。

之后：

- `transport.dropped` 给出 `(当前通话的 sessionId, 第 4 步记住的 offer 消息 ID)` 且仍是 outgoing →
  以 `offline` 结束，不发信令。其它 dropped 忽略。
- `ringing` → `remoteRinging: true`（仅 outgoing）。
- `answer`（仅 outgoing，且只处理第一个）→ 取消响铃定时器，状态变为 `connecting`，启动 `connectTimeout` 定时器，
  `await media.acceptAnswer(sdp)`，完成后把之前存着的对方候选按顺序 `addCandidate`。
- `end` → 结束，原因：`reject` → `rejected`；`busy` → `busy`；`failed` → `failed`；其它（含 `hangup` 和不认识的）
  → `remoteHangup`。不回任何信令。

**来电（收到 offer）**

- callId 在“已结束”集合里 → 忽略（防重放）。
- 当前是 idle 或 ended → 状态变为 `incoming`（`isOutgoing: false`，`contact` 为发送方，`callId` 为 offer 的），
  记住 offer 的 SDP，回 `ringing`，启动 `ringTimeout` 定时器（到时仍是 incoming → 以 `missed` 结束，不发信令）。
  **此时不创建媒体。**
- 当前有通话：发送方和 callId 都与当前通话相同 → 忽略（重复投递）；否则给**发送方**回
  `end(那个 offer 的 callId, busy)`，当前通话不受影响。
- `accept()`（仅 incoming）：取消响铃定时器，`createMedia()`，先订阅两个流，`await media.acceptOffer(sdp)`。
  抛异常 → 发 `end(failed)`，以 `failed` 结束。成功 → 发 `answer`，状态变为 `connecting`，启动 `connectTimeout`
  定时器，把存着的对方候选按顺序 `addCandidate`。`accept` 在这之后完成。
- `decline()`（仅 incoming）：发 `end(reject)`，以 `declined` 结束。
- 响铃期间收到 `end`（任何原因）→ 以 `missed` 结束。

**双方共同的规则**

- 对方的候选（`candidate` 信令）：`acceptOffer` / `acceptAnswer` 完成之前先存着，完成后按到达顺序加入；
  完成之后到的直接 `addCandidate`。任何时候都不能在它们完成之前调用 `addCandidate`。
- 本端的候选（`media.candidates`）：自己的 offer / answer 发出之前先存着，发出后按顺序各发一条 `candidate`
  信令；之后产生的直接发。
- `media.states`：`connected`（connecting 时）→ 取消连接定时器，状态变为 `active`，`connectedAt` 为当前时间。
  `failed`（connecting 或 active 时）→ 发 `end(failed)`，以 `failed` 结束。
- `connectTimeout` 到时仍是 connecting → 发 `end(failed)`，以 `failed` 结束。
- `hangup()`（outgoing / connecting / active）：发 `end(hangup)`，以 `hangup` 结束。其它状态无效果。
- `setMuted(muted)`（outgoing / incoming / connecting / active）：更新 `snapshot.muted`，媒体已创建则
  `media.setMuted(muted)`。idle / ended 无效果。
- `dismiss()`：ended → idle（一个全新的 `CallSnapshot()`）。其它状态无效果。
- `dispose()`：当前有通话（outgoing / connecting / active）按 `hangup()` 处理，incoming 按 `decline()` 处理；
  然后取消对 transport 的订阅并关闭 `changes`。可以重复调用。之后收到的信令不再处理。
- 发信令失败（`transport.send` 返回 null 或抛异常）除了 offer 以外都忽略，不影响状态。
- 任何方法里 `await` 之后都要重新确认“还是同一通通话、还在预期的状态”，否则放弃后续步骤
  （例如 `createOffer` 期间用户已经挂断）。

### 三、文档

- 新建 `docs/call-signaling.md`：信令格式（照 `call_signal.dart`）、如何加密和发送、两端的状态流转、
  超时、占线和防重放规则、已知限制（例如：重启后“已结束”集合清空，中继可以重放旧 offer 造成一次假响铃，
  但拿不到密钥，无法接通）。
- `docs/message-format.md` 的“明文”一节补一句：`t` 为 `call` 的内容是通话信令，只作为临时消息发送，见
  `docs/call-signaling.md`。

## 验收命令

```
flutter analyze --no-pub --no-fatal-infos lib test
flutter test --no-pub test/call test/messaging
flutter test --no-pub
```

三条都要通过，你改过的文件不能有新的 analyze 告警（现有的 23 条 info 可以不管）。
`lib/call/call_service.dart` 不能 import `flutter_webrtc`、`dart:io`、`storage/`、`relay/`。
