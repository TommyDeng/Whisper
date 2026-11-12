# 文件直传（WebRTC 数据通道）

双方同时在线时，文件一律经 WebRTC 数据通道点对点传输，不经服务器转发或存放。单文件上限 100 GiB。端到端加密复用 `FileCipher` 的分块加密；信令复用会话中继上的加密临时消息（和通话信令同一条通道，但类型不同，互不影响）。

对方离线，或直连失败（例如 ICE 只通了中继，失败原因 `no-direct`）时，才考虑走 `docs/file-relay.md` 的 R2 中转：不超过 100 MiB 须先弹出确认（加密后上传、最多保留 7 天），用户确认后才上传；取消则不发送。超过 100 MiB 不能中转，只说明原因，不提供中转选项。决策逻辑见 `lib/files/file_send_plan.dart`（`planFileSend`）。拒接、占线、超时、传到一半断网等其它直传失败不自动改走中转。

## 何时走直传

| 条件 | 路径 |
| --- | --- |
| 对方在线，且 0 ≤ size ≤ `FileCipher.maxDirectFileBytes`（100 GiB） | WebRTC 数据通道直传 |
| 对方离线或直连失败（`offline` / `no-direct`），且 size ≤ 100 MiB | 弹窗确认后走 R2 中转 |
| 对方离线或直连失败，且 size > 100 MiB | 拒绝，不能中转 |
| size > 100 GiB | 拒绝，失败原因 `too-large-direct` |

- 直传时双方必须同时在线。对方不在线、或自己没连上中继：失败原因 `offline`；若不超过 100 MiB，界面再询问是否改走中转。
- **文件数据永不经 TURN 传输**。PeerConnection 只配置 STUN，不加入 TURN 服务器，也不使用 `iceTransportPolicy: relay`。连接建立后检查选中的 ICE 候选对：任一侧是 `relay` 则立即结束，失败原因 `no-direct`，已发出的数据通道消息视为无效。传输中若路径变成 relay，同样以 `no-direct` 结束，绝不把剩余数据改走 TURN；不超过 100 MiB 时由界面询问是否改走 R2。
- 局域网、ZeroTier、公网 P2P（srflx/prflx）都算直连，可以使用。路径未知时只要不是 relay 也允许（避免误杀）。
- 同一时刻全局只进行一次直传（呼出或来传）。已有直传时再收到对方的直传 offer，回 `end(busy)`，当前传输不受影响；自己再发一个文件则以 `busy` 失败。经用户确认后的 R2 中转不受此限制，也可与直传同时进行。直传与语音通话互不影响（各自一条 PeerConnection）。

## 信令

信令是 `ChatContent.fileSignal`（`t` 为 `fsig`）的 `body`，一段 JSON，由 `lib/files/file_direct_signal.dart` 编解码。和通话信令一样：用会话密钥加密后经 `SessionClient.sendEphemeral` 发送，不落库、不写 outbox、不重发、不回回执。对方在线就转发，不在线就回 `{"type":"dropped","id"}`。中继只看到密文。

`MessagingService.sendFileSignal` / `fileSignals` 与 `sendCallSignal` / `callSignals` 并列；因对方离线被丢弃的临时消息仍走已有的 `signalDropped`（按消息 ID 区分是通话还是直传）。

```json
{"k":"offer","xfer":"<xferId>","sdp":"<SDP offer>","file":{/* FileOffer，且 via=direct */}}
{"k":"answer","xfer":"<xferId>","sdp":"<SDP answer>"}
{"k":"candidate","xfer":"<xferId>","cand":"<candidate>","mid":"<sdpMid>","line":0}
{"k":"end","xfer":"<xferId>","reason":"cancel|reject|busy|failed|no-direct"}
```

- `k`：种类，取值 `offer`、`answer`、`candidate`、`end`。
- `xfer`：本次直传 ID，由发送方用 `MessageCodec.newMessageId()` 生成，最长 64 个字符。
- `sdp`：仅 `offer` / `answer`，最长 20000 个字符。
- `file`：仅 `offer`。必须是合格的 `FileOffer` 且 `via` 为 `direct`；大小必须在 0 到 100 GiB 之间。
- `cand` / `mid` / `line`：仅 `candidate`，限制与通话信令相同。
- `reason`：仅 `end`，取值见上；接收方遇到不认识的 `reason` 时按对方取消处理。

格式不对、种类不认识、字段超长、`file` 不合格时 `FileDirectSignal.decode` 返回 `null`，接收方直接忽略。不记录 xferId、SDP、候选地址、文件 ID 或密钥。

### 状态机（摘要）

**呼出**

1. 计算明文哈希、生成 `FileKeys` 和 `FileOffer(via: direct)`，创建无音视频、仅数据通道的 PeerConnection，`createOffer()` 后发 `offer`。
2. `transport.send` 返回 `null`（没连上中继）或以 `offline` 结束；否则记住这条临时消息的 ID。对方不在线时中继把这条 offer 丢回来，同样以 `offline` 结束。
3. 启动 `offerTimeout`（默认 120 秒）：对方一直不回 answer 则以 `timeout` 结束，并发 `end(cancel)`。
4. 收到 `answer` 后取消定时器，应用 SDP，进入连接中，启动 `connectTimeout`（默认 30 秒）。
5. 数据通道打开后检查 ICE 路径；是 relay 则发 `end(no-direct)` 并以 `no-direct` 结束。通过后按数据通道协议传文件。
6. 收到 `end(reject)` → `declined`；`end(busy)` → `busy`；`end(no-direct)` → `no-direct`；`end(cancel)` 或其它 → 按取消/失败处理。自己取消发 `end(cancel)`。

**来传**

1. 收到 `offer`：xferId 在“已结束”集合里则忽略（防重放，保留最近 64 个）。否则进入“待接受”，界面提示用户选保存位置或拒绝。此时先缓冲对方的 ICE 候选，**先不创建 PeerConnection**。
2. 已有直传时：发送方和 xferId 都与当前直传相同则忽略（重复投递），否则向发送方回 `end(busy)`。
3. 用户拒绝：回 `end(reject)`，结束。`offerTimeout` 内未接受：以 `timeout` 结束，不发信令（对方自己会超时）。
4. 用户接受并选好保存位置：创建 PeerConnection，`acceptOffer`，回 `answer`，进入连接中，启动 `connectTimeout`。媒体/数据通道失败则回 `end(failed)`。
5. 连接后同样检查 ICE 路径；是 relay 则发 `end(no-direct)`。通过后打开 `FileReceiver`（目标为用户所选路径），开始收数据。

ICE 候选的缓冲与补发规则与通话相同：自己的 offer/answer 发出之前先存本端候选，发出后再发；对方的 SDP 应用完之前先存对端候选，完成后再加入。

## 文件消息

`FileOffer` 增加可选字段 `via`：

```json
{"v":1,"id":"<fileId>","name":"电影.mkv","size":1234567890,"key":"...","np":"...","hash":"...","via":"direct"}
```

- 缺省或 `"r2"`：中转文件，`size` 必须在 0 到 100 MiB 之间（与原来相同，已发出的中转消息仍能解码）。
- `"direct"`：直传文件，`size` 必须在 0 到 100 GiB 之间。其它 `via` 值拒绝。
- `encode()` 只在 `via` 为 `direct` 时写出该字段，中转消息的编码保持不变。
- 直传成功后，发送方再发一条普通的 `file` 消息（和文本一样落库、去重、回执）。接收方在直传完成时先记下 `fileId → 本地路径`，收到这条文件消息后再写入 `file_transfers`。界面上这条气泡按“已保存”显示。
- 直传文件不在 R2 上：气泡不显示“只能成功下载一次”，也不提供“下载”按钮。本地文件不在了，说明“大文件不会存在服务器上，无法再次下载。”

## 端到端加密与数据通道协议

加密完全复用 `FileCipher` / `FileReceiver`：1 MiB 明文一块，XChaCha20-Poly1305，BLAKE2b-256 整文件哈希。`FileReceiver` 的 size 上限改为 100 GiB（中转下载仍由 `FileRelayTransfer` 在调用前按 100 MiB 拒绝）。任何时候内存里最多一个密文块再加若干个 16 KiB 的数据通道分片，不把整个文件读进内存。

WebRTC 数据通道是可靠、有序的，标签为 `whisper-file`。一条密文块可能超过数据通道单条消息上限，所以按 `fragmentSize = 16 KiB` 切开再发。发送前按 `bufferedAmount` 做背压（高水位 1 MiB，低水位 256 KiB）。

控制消息是文本 JSON；密文分片是二进制。

控制消息：

```json
{"t":"start","next":0}
{"t":"ack","i":0}
{"t":"done"}
{"t":"fail","reason":"corrupt"}
{"t":"abort"}
```

- 数据通道打开且路径检查通过后，接收方用 `FileReceiver.nextIndex`（可能因已有 `.part` 而不是 0）发 `start`。
- 发送方从 `next` 起逐块 `sealChunk`，把密文按 16 KiB 分片发送；每块收齐并写入后接收方回 `ack`。发送方等到这块的 `ack` 再发下一块（内存里只有一块）。
- 源文件在发送过程中读不了或大小变了：发送方发 `abort`，失败原因 `changed`。
- 某一块认证失败或长度不对：接收方不写入、`nextIndex` 不变，发 `fail(corrupt)`，删除临时文件，失败原因 `corrupt`。
- 全部块写完并 `finish` 校验通过后，接收方发 `done`，发送方才认为成功。
- 任何一方取消：发信令 `end(cancel)`，并在数据通道上发 `abort`（若通道已开）。接收方取消时保留 `.part`（与中转取消一致）；`corrupt` 则删除。

二进制分片（大端，头 16 字节）：

```
0x57 0x46 0x01 0x00 | chunkIndex uint32 | offset uint32 | total uint32 | payload
```

`total` 是这一密文块的总长度，不得超过 `chunkSize + tagLength`；`offset + payload.length` 不得超过 `total`。不合格的分片忽略（不写入、不推进）。

## 进度、取消、失败原因、断线

- 进度：已完成的明文字节数和总字节数。发送方按已得到 ACK 的块计算（最后一块按实际明文长度）；接收方按已写入的块计算。
- 取消：进行中可取消；失败记录可关掉。发送方取消后不再发文件消息。
- 传输中断（数据通道关闭、PeerConnection 失败、`progressTimeout` 默认 60 秒内没有任何进度）：失败原因 `network`。接收方保留 `.part`。本次直传结束，不会自动重连。再次发送会生成新的文件 ID 和密钥，作为一次新的传输从头开始——**同一文件的断点续传（含应用重启后恢复）本阶段不做**，见文末遗留。
- 失败原因与界面文案（在已有中转文案之外新增或沿用）：

| 代码 | 中文 |
| --- | --- |
| `too-large` | 文件太大，不能超过 100 MB。（仅中转路径，行为不变） |
| `too-large-direct` | 文件太大，不能超过 100 GB。 |
| `offline` | 对方不在线，无法点对点直传。 |
| `no-direct` | 当前没有点对点直连（只通了中继），文件不能经过语音中继传输。 |
| `busy` | 对方正忙，请稍后再试。 |
| `declined` | 对方拒绝了这次文件传输。 |
| `timeout` | 对方没有接受这次传输。 |
| `network` | 网络出错，请稍后重试。 |
| `corrupt` | 文件在传输中损坏，无法保存。 |
| `changed` | 源文件在上传过程中被改动或无法读取。 |
| `failed` | 传输失败，请稍后重试。 |

## 界面

- 选文件仍用现有的“发送文件”按钮和 `file_selector`。阅后即焚开启时按钮禁用的规则不变（直传同样不支持阅后即焚）。
- 发出直传后，输入栏上方的上传条除进度和取消外，写明“正在直传，请双方保持在线。文件不经服务器中转。”
- 收到直传 offer 时，在输入栏上方显示：安全文件名、大小、说明“对方要向你发送一个文件。双方必须同时在线，文件走点对点直连，不会经过服务器中转。”以及“接受”“拒绝”。接受时用 `getSaveLocation`（默认文件名是 `offer.safeName`），目标已存在则确认是否覆盖；取消选择等于还没接受，offer 仍在。
- 对方离线或直连失败（`offline` / `no-direct`）且文件 ≤ 100 MiB：先弹出确认（说明将加密后上传到服务器、最多保留 7 天），只有用户点“确认发送”才走中转；点取消则不发送。超过 100 MiB 只说明无法中转，不提供发送按钮。
- 接受后同一位置改为进度和取消。失败时显示对应中文原因，可关掉。
- 直传成功后的文件气泡：已保存、可打开所在位置；不出现中转的“只能成功下载一次”和“下载”按钮。
- 大小格式：满 1 GiB 起用 GB（例如 `1.5 GB`、`12 GB`），不足 1 GiB 的仍用现有 B / KB / MB。

测试里不创建真实的 WebRTC 连接、不访问外网：信令用内存里的假通道，数据通道用成对的假实现（可指定 ICE 路径为局域网或 relay）。路径决策（`planFileSend`）用单位测试覆盖，不必在集成测试里造出超过 100 MiB 的文件。选文件和保存位置仍用假的 `FileLocationPicker`。

## 完成标准

- `docs/message-format.md` 补充 `t: fsig`；`docs/file-relay.md` 指向本文。`docs/HANDOFF.md` 更新进度。
- `flutter analyze --no-fatal-infos lib test` 没有新增问题（基线 18 条 info），`flutter test` 全过（现有 345 个测试不能少）。本阶段不改 `worker/`，不部署，不建云资源。
- 测试覆盖：双方在线时小文件也走直传；`planFileSend` 的在线/离线/无直连/超限决策；直传往返（含空文件以外的多块）；对方离线；拒绝；占线；仅 TURN / relay 路径被拒绝且不发文件数据；取消；传输中断（`network`，接收端保留 `.part`）；认证失败（`corrupt`）；`FileOffer` 的 `via` 与大小上限；信令编解码；界面文案、中转确认弹窗、来传接受/拒绝、直传气泡不出现中转下载提示、GB 大小格式。

## 本阶段不做（遗留）

- 传输中断或应用重启后的断点续传（接收端虽保留 `.part`，再次发送是一次新的传输）。
- 暂停 / 继续。
- 接收前检查磁盘剩余空间。
- 多数据通道并行、按块 NAK 选择性重传。
