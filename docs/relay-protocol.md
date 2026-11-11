# 中继协议（会话与配对）

中继是一个 Cloudflare Worker（`worker/`），线上域名 `whisper.tommydeng.org`。它只转发和暂存密文，看不到明文、身份或公钥。所有 `payload` 字段对中继来说都是不透明字符串（客户端放 base64 密文），中继不解析、不记录日志。

入口校验（ID 格式、查询参数、是否 WebSocket 升级）在 `worker/src/index.ts` 完成；通过后请求原样交给对应的 Durable Object。常量集中在 `worker/src/relay_limits.ts`。

所有帧都是 JSON 文本。下文“回复”指发给当前连接，“转发”指发给对方连接。

通用规则（两个 DO 都适用）：

- 帧长度超过 `MAX_FRAME_CHARS` → 回复 `{"type":"error","error":"too-large"}`。
- 不是合法 JSON → `{"type":"error","error":"invalid-json"}`；不是 JSON 对象 → `error: "expected-object"`；`type` 不认识 → `error: "unknown-type"`。
- `{"type":"ping"}` → 回复 `{"type":"pong"}`。
- 限速：每条连接在 `RATE_LIMIT_WINDOW_MS` 窗口内最多处理 `RATE_LIMIT_MAX_FRAMES` 帧（ping 也计数）；超出的帧不处理，回复 `{"type":"error","error":"rate-limited"}`。
- 出错不断开连接（除非下文明确说要关闭）。
- 使用 WebSocket Hibernation API（`ctx.acceptWebSocket`、`webSocketMessage`、`webSocketClose`、`webSocketError`），连接的身份信息放在 `serializeAttachment` 里，不能只放内存。
- 不写任何日志（不 `console.log` payload、ID、IP）。

## 一、会话中继 SessionDO

`GET /session/<sessionId>?peer=a|b`，WebSocket 升级。`sessionId` 由配对时邀请人随机生成，即 DO 名称；`peer` 是固定身份：邀请人为 `a`，加入者为 `b`。

### 连接

- 接受连接后依次发送：
  1. `{"type":"welcome","peer":"a","peerOnline":true|false}`（`peerOnline` 表示对方此刻是否在线）；
  2. 队列中发给本方、尚未确认且未过期的全部消息，按入队顺序，每条 `{"type":"msg","id","payload","ts"}`。
- 对方在线时，向对方转发 `{"type":"peer-online"}`。
- 同一个 `peer` 再次连接：以新连接为准，旧连接用关闭码 `4001`（原因 `replaced`）关闭。这种情况下不向对方发 `peer-offline`。
- 连接关闭且该 `peer` 已没有其它连接时，向对方转发 `{"type":"peer-offline"}`。

### 客户端 → 中继

| 帧 | 行为 |
|---|---|
| `{"type":"msg","id","payload"}` | 校验后入队（持久化），回复 `{"type":"stored","id"}`；对方在线则同时转发 `{"type":"msg","id","payload","ts"}`。`ts` 是中继收到时的毫秒时间戳。 |
| `{"type":"msg","id","payload","ephemeral":true}` | 不入队。对方在线则转发 `{"type":"msg","id","payload","ts"}`（不回复 `stored`）；对方不在线则回复 `{"type":"dropped","id"}`。用于通话信令。 |
| `{"type":"ack","id"}` | 删除队列中**发给本方**、ID 为 `id` 的消息；确有删除且对方在线时，向对方转发 `{"type":"delivered","id"}`。找不到则忽略，不报错。不能用来删除自己发出的消息。 |

`msg` 的校验，失败时回复 `{"type":"error","error":<码>,"id":<id，若是字符串>}`，不入队、不转发：

- `id` 不是字符串或不匹配 `MESSAGE_ID` → `bad-id`
- `payload` 不是字符串或为空 → `bad-payload`
- `payload` 长度超过 `MAX_PAYLOAD_CHARS` → `too-large`
- 接收方队列已有 `MAX_QUEUED_PER_PEER` 条 → `queue-full`

`ack` 的 `id` 不是字符串 → `bad-id`。

重复发送：同一发送方重发一个仍在队列里的 `id` 时不重复入队，只回复 `stored`。

### 存储与过期

- 队列用 DO 的 KV 存储，键 `q:<接收方 peer>:<12 位零填充的递增序号>`，值 `{ "id": string, "payload": string, "ts": number }`。序号从 1 开始递增，计数器另存（键名自定，不以 `q:` 开头）。投递时按 `q:<peer>:` 前缀 `list`，键序即入队顺序。
- 消息保留到被 `ack`，最长 `OFFLINE_TTL_MS`（7 天）。用 `isExpired(ts, Date.now())` 判断；过期消息不投递，并从存储中删除。
- 清理时机：每次有连接接入时清理该 DO 的过期消息；另外用 alarm 兜底——队列非空时保证有一个不晚于“最早一条消息过期时刻”的 alarm，`alarm()` 里删除过期消息，仍有剩余则重新设置。
- 未确认的消息在接收方每次重连时都会再次投递，客户端按 `id` 去重。

## 二、配对 InviteDO

`GET /invite/<inviteId>?role=inviter|joiner&key=<key>[&expires=<unix 秒>]`，WebSocket 升级。

- `inviteId`：邀请码里 16 字节 token 的 base64url（22 个字符），即 DO 名称。
- `key`：客户端本地随机生成，不出现在邀请码里。邀请人的 key 在登记时绑定；加入者的 key 在发出配对请求时绑定。之后只有持相同 key 的连接才被当作同一方。
- `expires`：仅邀请人首次登记时需要，邀请的过期时刻（unix 秒）。

### 状态

存储键 `invite`，值：

```ts
{
  inviterKey: string,
  expiresAt: number,          // 毫秒
  state: "open" | "requested" | "responded" | "done",
  joinerKey?: string,
  request?: string,           // 加入者的配对请求 payload
  response?: { accepted: boolean, payload: string }
}
```

`open` → 加入者发请求 → `requested` → 邀请人批准或拒绝 → `responded` → 加入者确认收到 → `done`。

### 升级前的拒绝（HTTP 响应，JSON `{"ok":false,"error":<码>}`）

按下面顺序判断：

1. 记录存在但 `Date.now() >= expiresAt` → 删除该 DO 的全部存储，按“记录不存在”继续判断，但加入者得到的是 `410 invite-expired`。
2. 记录不存在：
   - `joiner` → `404 invite-not-found`（刚因过期被删的情况为 `410 invite-expired`）
   - `inviter`：`expires` 必须是整数，且 `now < expires*1000 <= now + INVITE_MAX_TTL_MS + INVITE_CLOCK_SKEW_MS`，否则 `400 bad-expiry`；合法则登记（`state: "open"`），并设置在 `expiresAt` 触发的 alarm。
3. 记录存在：
   - `inviter` 的 `key` 与 `inviterKey` 不同 → `403 forbidden`
   - `state` 为 `done` → `410 invite-used`（两种角色都一样）
   - `joiner` 且已绑定 `joinerKey`、与本次 `key` 不同 → `410 invite-used`

通过后接受连接。同一角色、同一 key 再次连接时，旧连接用 `4001`（`replaced`）关闭。

### 连接后

中继依次发送：

1. `{"type":"welcome","role":"inviter"|"joiner","state":<当前状态>}`
2. 邀请人且 `state` 为 `requested`：`{"type":"pair-request","payload":<request>}`
3. 加入者（已绑定的那个）且 `state` 为 `responded`：`{"type":"pair-response","accepted","payload"}`

### 客户端 → 中继

| 发送方 | 帧 | 要求的状态 | 行为 |
|---|---|---|---|
| joiner | `{"type":"pair-request","payload"}` | `open` | 绑定 `joinerKey`，保存 `request`，状态改为 `requested`；回复 `{"type":"stored"}`；邀请人在线则转发 `{"type":"pair-request","payload"}`。 |
| inviter | `{"type":"pair-response","accepted":bool,"payload"}` | `requested` | 保存 `response`，状态改为 `responded`；回复 `{"type":"stored"}`；已绑定的加入者在线则转发 `{"type":"pair-response","accepted","payload"}`。 |
| joiner（已绑定） | `{"type":"pair-done"}` | `responded` | 状态改为 `done`，删除 `request` 和 `response`；邀请人在线则转发 `{"type":"pair-done"}`；随后用 `1000` 关闭该邀请的所有连接。记录本身保留到过期，用来拒绝重复使用。 |

错误（回复 `{"type":"error","error":<码>}`）。按“角色 → 状态 → 字段”的顺序检查，报第一个不满足的：

- 角色不对（例如邀请人发 `pair-request`） → `not-allowed`
- 状态不对 → `bad-state`。例外：状态已不是 `open` 时，**未绑定**的加入者发 `pair-request` → `invite-used`，并用 `4003` 关闭该连接。
- `payload` 不是字符串，或 `pair-request` 的 `payload` 为空 → `bad-payload`（`pair-response` 的 `payload` 允许为空字符串，拒绝时可以不带内容）
- `payload` 长度超过 `MAX_PAIR_PAYLOAD_CHARS` → `too-large`
- `accepted` 不是布尔值 → `bad-accepted`

### 过期

alarm 在 `expiresAt` 触发：用 `4002`（`expired`）关闭所有连接，删除全部存储。之后加入者再连得到 `404 invite-not-found`。

## 三、客户端如何使用（概要，非中继职责）

1. 邀请人 A 生成邀请码（公钥 + token + 过期时间，见 `lib/pairing/invitation_code.dart`），以 `inviter` 身份连上 `/invite/<token>` 并保持（或之后重连）等待请求。
2. 加入者 B 粘贴邀请码，以 `joiner` 身份连接，发送 `pair-request`：payload 是用 A 的公钥加密的 B 的公钥等信息。
3. A 界面显示 B 的安全码，用户批准或拒绝。批准时 A 随机生成 `sessionId`，放在加密的 `pair-response` payload 里。
4. B 收到后发 `pair-done`，双方各自保存联系人，之后都连 `/session/<sessionId>`（A 为 `peer=a`，B 为 `peer=b`）收发消息。

## TURN 临时凭据

`GET /turn-credentials` 返回一组短期 ICE 服务器配置，供语音通话在直连不通时走 Cloudflare Realtime TURN 中继：

```json
{"ok":true,"iceServers":[{"urls":["stun:…"]},{"urls":["turn:…","turns:…"],"username":"…","credential":"…"}]}
```

- Worker 用两个 secret（`TURN_KEY_ID`、`TURN_KEY_API_TOKEN`）向 Cloudflare 换凭据，有效期 4 小时；长期密钥不下发。
- 没配置 secret 时返回 501 `turn-not-configured`；上游失败返回 502。客户端拿不到凭据就只用 STUN。
- 响应不缓存，Worker 不记录请求和凭据。
- 这个接口目前不需要身份验证，任何人都能领到短期凭据并消耗 TURN 流量；用量需在 Cloudflare 控制台关注。
- 客户端设 `WHISPER_FORCE_RELAY=1` 时只用中继候选，用来验证中继路径。

## 文件中转（R2）

离线文件的密文分块暂存在 R2（绑定 `FILES`），走普通 HTTP，不经过 Durable Object：

- `PUT /file/<fileId>/<index>` 上传一个密文块（`201`；已存在 `409 chunk-exists`，超限 `413 chunk-too-large`，空体 `400 empty-chunk`）。
- `GET /file/<fileId>/<index>` 下载一个密文块（不存在或已过 7 天 `404 not-found`）。
- `DELETE /file/<fileId>` 删除这个文件的全部块。

`fileId` 是 43 个 URL 安全字符，起访问凭据的作用；`index` 为 `0`–`127`。实现在 `worker/src/files.ts`，Worker 不记录请求信息。完整规则、分块与加密方式见 [file-relay.md](file-relay.md)。
