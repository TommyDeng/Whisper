# 通话信令

语音通话的信令（SDP offer/answer、ICE 候选、响铃、挂断）不经过任何新的通道，而是作为端到端
加密的**临时消息**，走现有的会话中继。中继只看到密文，不暂存：对方在线就转发，不在线就回
`{"type":"dropped","id"}`。音频本身走 WebRTC，本文只描述信令。

## 信令格式

信令是 `ChatContent.call` 的 `body`，一段 JSON，由 `lib/call/call_signal.dart` 编解码：

```json
{"k":"offer","call":"<callId>","sdp":"<SDP offer>"}
{"k":"answer","call":"<callId>","sdp":"<SDP answer>"}
{"k":"candidate","call":"<callId>","cand":"<candidate>","mid":"<sdpMid>","line":0}
{"k":"ringing","call":"<callId>"}
{"k":"end","call":"<callId>","reason":"hangup|reject|busy|failed"}
```

- `k`：种类，取值 `offer`、`answer`、`candidate`、`ringing`、`end`。
- `call`：通话 ID，由主叫用 `MessageCodec.newMessageId()` 生成，最长 64 个字符。
- `sdp`：仅 `offer` / `answer`，最长 20000 个字符。
- `cand` / `mid` / `line`：仅 `candidate`；`cand` 最长 2000 个字符，`mid` 可选且最长 64 个字符，
  `line` 可选且在 0 到 1024 之间。
- `reason`：仅 `end`，取值 `hangup`（挂断/取消）、`reject`（拒接）、`busy`（占线）、`failed`（媒体错误）；
  接收方遇到不认识的 `reason` 时按对方挂断处理。

格式不对、种类不认识、字段超长时 `CallSignal.decode` 返回 `null`，接收方直接忽略。

## 加密与发送

发送侧（`MessagingService.sendCallSignal`）：

1. 生成消息 ID（`MessageCodec.newMessageId()`），并用会话密钥和**自己的角色**
   （`contact.peerRole`）加密 `ChatContent.call(body, sentAt: 当前毫秒)`；附加数据绑定
   会话 ID、发送方角色和消息 ID，和聊天消息完全一样。
2. 调 `SessionClient.sendEphemeral(id, payload)`：未连接返回 `false`，发送方返回 `null`；
   连接着就作为临时消息发出。
3. 不落库、不写 outbox、不重发、不更新联系人最后消息时间。信令正文超过
   `MessageCodec.maxSignalBytes` 时 `MessageCodec.seal` 抛 `ArgumentError`，原样交给调用方。

接收侧（`MessagingService._onMessage`）解密成功后，如果 `t` 为 `call`，把
`(contact, body)` 发到 `callSignals`，然后照常 `ack`；不落库、不回回执、不发通知。
`SessionClient.dropped` 帧转成 `signalDropped` 的 `(sessionId, id)`，由 `CallService`
用来识别“对方不在线”。

## 状态机

`lib/call/call_service.dart` 的 `CallService` 一次只处理一通通话，状态通过
`CallSnapshot` 暴露：`idle` → `outgoing` / `incoming` → `connecting` → `active` →
`ended`，`ended` 经 `dismiss()` 回到 `idle`。每次变化都往 `changes`（广播流）发一个新快照。

### 呼出

1. `start(contact)`：`idle` / `ended` 时生成 callId，进入 `outgoing`；先订阅
   `media.candidates` 和 `media.states`，再 `createOffer()`。媒体打不开则以 `failed` 结束，
   不发任何信令。
2. 发 `offer`。`transport.send` 返回 `null`（没连上中继）则以 `offline` 结束；否则记住这条
   临时消息的 ID，并启动 `ringTimeout`。
3. `ringing` → `remoteRinging: true`；`answer` → 取消响铃定时器，进入 `connecting`，
   启动 `connectTimeout`，应用 SDP answer；`media.states` 为 `connected` 时进入 `active`。
4. 结束原因：`reject` → `rejected`、`busy` → `busy`、`failed` → `failed`、其它（含
   `hangup`）→ `remoteHangup`。对方先挂了不回复。

### 来电

1. 收到 `offer`：callId 在“已结束”集合里则忽略（防重放）；否则从 `idle` / `ended` 进入
   `incoming`，记住 SDP，回 `ringing`，启动 `ringTimeout`，**此时不创建媒体**。
2. 已有通话时：发送方和 callId 都与当前通话相同则忽略（重复投递），否则向发送方回
   `end(<那个 offer 的 callId>, busy)`，当前通话不受影响。
3. `accept()`：取消响铃定时器，创建媒体并订阅两个流，`acceptOffer(sdp)` 成功后回 `answer`，
   进入 `connecting`，启动 `connectTimeout`。媒体失败则回 `end(failed)` 并以 `failed` 结束。
4. `decline()`：回 `end(reject)`，以 `declined` 结束。响铃期间收到对方任何 `end` 都以
   `missed` 结束。

### ICE 候选

- 对方的候选：`acceptOffer` / `acceptAnswer` 完成之前先按到达顺序存起来，完成后再加入；
  完成之后到达的直接 `addCandidate`。
- 本端的候选：自己的 offer / answer 发出之前先存起来，发出后按顺序各发一条 `candidate`；
  之后产生的直接发。

## 超时、占线与防重放

- `ringTimeout`（默认 45 秒）：呼出后对方一直不接 → 发 `end(hangup)`，以 `timeout` 结束；
  来电一直不接 → 以 `missed` 结束，不发信令。
- `connectTimeout`（默认 30 秒）：进入 `connecting` 后音频连接迟迟未建立 → 发
  `end(failed)`，以 `failed` 结束。
- 占线：有通话时收到另一个 offer，向发送方回 `end(busy)`。
- 防重放：每通通话结束都把 callId 记入“已结束”集合（保留最近 64 个）；中继重放已结束通话的
  `offer` 会被直接忽略。`ended` 状态之外，其它信令只有在发送方会话 ID 和 callId 都与当前
  通话一致时才处理。

## 已知限制

- “已结束”集合只在内存里，客户端重启后清空。中继可以重放旧 `offer`，造成一次假响铃；
  但旧通话的会话密钥和信令绑定在会话 ID / 角色 / 消息 ID 上，重放的密文解不开，也无法接通。
- 信令是临时消息，对方离线时中继不暂存；呼出方通过 `dropped` 得知对方不在线并以 `offline`
  结束，离线期间的呼叫不会稍后送达。
- 目前没有前向保密，会话密钥是静态的（见 `docs/message-format.md`）。
