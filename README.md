# 耳语 Whisper

亲友之间的端到端加密聊天与语音客户端（Flutter，Windows / Linux 优先）。

文档见 `docs/`。

## WebRTC spike

`spike/` 是 Stage 2 的 `feat/webrtc-spike`：两台桌面客户端用粘贴的房间码配对，经本地 Cloudflare Worker + Durable Object 交换信令，然后：

1. 建立 `flutter_webrtc` 1:1 音频（DTLS-SRTP，本 spike **没有**应用层 E2EE）；
2. 打开可靠有序的 DataChannel，发送一条文字和一份测试文件，并测量吞吐；
3. 显示当前 ICE 路径：局域网 host、ZeroTier、公网 P2P（srflx/prflx）、中继（relay）；
4. 尝试先走局域网，再走 ZeroTier，最后才放开公网候选。

信令项目只供 `wrangler dev` 在本机跑。**不要部署，也不要购买 TURN / 证书。** 房间码没有鉴权，信令上的 SDP 是明文；媒体和 DataChannel 走 DTLS。

### 本地双机测试

两台机器都要能访问跑信令的那一台。建议先在同一局域网测，再测 ZeroTier。

准备：

- Flutter 3.47.9（Dart 3.13）
- Node.js 22
- Linux 构建库：`clang`、`cmake`、`ninja-build`、`pkg-config`、`libgtk-3-dev`、`liblzma-dev`、`libstdc++-14-dev`、`libglu1-mesa`、`libpulse-dev`。运行时还需要 `iproute2`（`ip -j addr` 用来识别网卡）
- Windows：Visual Studio 的“使用 C++ 的桌面开发”
- 可选：麦克风、扬声器、双方都加入的 ZeroTier 网络

在机器 A 启动信令（监听局域网，不部署）：

```bash
cd spike/signaling
npm ci
npm run dev
```

这等于 `wrangler dev --ip 0.0.0.0 --port 8787`。需要的话在 A 的防火墙上放行 TCP 8787。不要把这个端口暴露到公网。

两台机器各自启动客户端：

```bash
cd spike/client
flutter pub get
flutter run -d linux
# Windows: flutter run -d windows
```

操作：

1. 机器 A 点「生成房间码」，把那串码用你自己的渠道发给机器 B。
2. 两台的信令地址都填 `ws://<机器A的局域网IP>:8787`（同一台机器自测可用 `ws://127.0.0.1:8787`）。B 粘贴同一个房间码。
3. 两边都点「连接」。先连上的一方是 offerer，第二个人进入后会自动呼叫。
4. 看顶部路径横幅和 DTLS 状态。横幅来自 `getStats` 选中的**本机**候选：
   - **局域网**：本机 host 地址落在物理网卡上
   - **ZeroTier**：本机 host 地址落在 `zt*` 或描述里带 ZeroTier 的网卡上
   - **公网 P2P**：选中的是 srflx 或 prflx
   - **中继**：选中的是 relay。本 spike 没有配置 TURN，正常测试不应出现；显示逻辑留给后面的 `feat/turn`
5. 在数据通道打开后发送一句文字，再发送 1 / 8 / 32 MiB 测试文件，或选一个不超过 256 MiB 的本地文件。发送端会先等 `file-start-ack`，再送带序号的二进制帧；缺块会按 `file-nak` 重传。界面上的 MiB/s 是**接收端**从开始接收到校验完成的耗时。
6. 挂断后再点「重新呼叫」只会由 offerer 发起。

可选自检：点「健康检查」，应看到 `{"ok":true,"service":"whisper-webrtc-spike"}`。

### 三条路径怎么摆

| 摆法 | 预期横幅 |
|---|---|
| 两台在同一物理局域网，ZeroTier 可开可关 | 局域网。连通后不再发布更低优先级候选 |
| 两台不在同一物理网，但在同一个 ZeroTier 网络 | ZeroTier。没有局域网 host 时，采集结束或最多再等 4 秒就发布 ZeroTier |
| 局域网和 ZeroTier 同时在 | 先只发布局域网 host。默认 5 秒还没连通才放开 ZeroTier 和公网候选。秒数可以在界面里改 |
| 宿主候选是 `*.local` | 无法分辨网卡，候选会全部发布，横幅会标明 mDNS |
| 只有公网打洞 | 公网 P2P（STUN 使用 `stun:stun.cloudflare.com:3478`，不需要账号） |

关掉 ZeroTier 之后，只要 STUN 打洞成功，通话和 DataChannel 仍应能建立。本 spike 没有 TURN，对称 NAT 打洞失败时这里没有中继兜底。

### 自动吞吐跑法

编译一次后，可以用环境变量让两个进程自己连上并传 8 MiB。两边写完结果 JSON 后退出。

```bash
cd spike/signaling && npm run dev
# 另开两个终端，工作目录都是 spike/client
SPIKE_AUTORUN=1 SPIKE_ROLE=offerer SPIKE_URL=ws://127.0.0.1:8787 SPIKE_ROOM=autorun1 \
  SPIKE_BYTES=8388608 SPIKE_RESULT=/tmp/spike-offerer.json \
  flutter run -d linux
SPIKE_AUTORUN=1 SPIKE_ROLE=answerer SPIKE_URL=ws://127.0.0.1:8787 SPIKE_ROOM=autorun1 \
  SPIKE_RESULT=/tmp/spike-answerer.json \
  flutter run -d linux
```

`SPIKE_ROLE` 不填时，设置了 `SPIKE_BYTES` 的一侧会请求当 offerer，后加入房间也可以当主叫。两边都会写结果 JSON：有 `SPIKE_RESULT` 就写到那个路径，否则写当前目录的 `spike-result-offerer.json` / `spike-result-answerer.json`。offerer 的 `textAck` 表示收到了文字回执；answerer 的 `helloSeen` / `textAckSent` 表示收到了测试文字并且发出了回执。

两台机器同时在物理局域网和 ZeroTier 上时，自动策略会选局域网。要单独看某一条路径，两边都设置 `SPIKE_ONLY_TIER`：

- `lan`：只发布局域网 host
- `zerotier`：只发布 ZeroTier host
- `srflx`：只发布公网 srflx

不设则保持原来的自动顺序（局域网，然后 ZeroTier，超时再放开其余）。这个开关不会回退到别的层级。结果 JSON 里的 `onlyTier` 是实际使用的值，未设置时为 `null`。

截图时两边加上 `SPIKE_HOLD_SECONDS=30`（或你需要的秒数）。结果先写入 JSON，窗口再停留这段时间才退出。只有一侧停留的话，另一侧退出会把通话拆掉。

Autorun 的超时按进度计算：连续 30 秒没有新的文件块才写成 `error=stall`。传输还在走时不会因为整段通话超过两分钟就先写一份没有校验结果的 JSON。

同一对机器上，32 MiB 走物理局域网数据通道大约 9.8 MiB/s，只走 ZeroTier（MTU 2800）大约 0.81 MiB/s，0 次重传。桌面端 `onBufferedAmountLow` 不会回调，发送端只能轮询 `getBufferedAmount`。SCTP 再叠在 2800 字节的 ZeroTier 上，小分块会把吞吐打得很低。数据通道还可以用 `SPIKE_CHUNK`、`SPIKE_BUFFER_HIGH_KB`、`SPIKE_BUFFER_LOW_KB`、`SPIKE_POLL_MS` 调整，但大文件应改走直连。

`SPIKE_FILE_TRANSPORT=direct` 时，若选中的 ICE 路径是局域网或 ZeroTier 的 host 地址，answerer 在那个地址上听一个 TCP 端口，经数据通道把端口告诉 offerer。握手用双方 DTLS 指纹排序后派生的密钥做 HMAC，文件按块做 AES-GCM，收完再对明文做 SHA-256。结果 JSON 的 `fileTransport` 是 `direct` 或 `datachannel`，`mibPerSec` 是这一次实际走的通道。直连默认 256 KiB 一块，可用 `SPIKE_DIRECT_CHUNK_KB` 改。路径不是局域网 / ZeroTier，或直连没接上时，自动改回数据通道，并在 `directError` 里写原因。不设 `SPIKE_FILE_TRANSPORT` 时仍走数据通道。

### 这次 spike 已经能确定的事

下面的通话和吞吐是 2026-11-02 在一台 Linux 虚拟机上、用两个本机进程打出来的（`flutter_webrtc` 1.6.3，8 MiB，SHA-256 通过）。不是两台物理机，也没有 ZeroTier 网卡。

- 信令可用：先连接的是 offerer，第二个人是 answerer，SDP/候选会转给对方，离开会通知。
- 有 PulseAudio 时双方都能打开麦克风并收到远端音频。DTLS 状态是 `connected`，密码套件 `TLS_AES_128_GCM_SHA256`，SRTP 是 `AES_CM_128_HMAC_SHA1_80`。
- 选中的路径是局域网 host `172.30.0.2`。日志里只发布了 `lan` 候选，连通后调度器停在「不再发布更低优先级候选」。回环和 srflx 没有发给对端。
- 同一条可靠有序 DataChannel 上，8 MiB 的接收端吞吐：8 KiB 分块约 **2.9 MiB/s**（2773 ms），16 KiB 约 **5.0 MiB/s**（1606 ms），64 KiB 约 **5.1 MiB/s**（1561 ms）。16 KiB 和 64 KiB 大约是 43 Mbit/s，离虚拟机网卡和千兆局域网都还很远。分块再小，平台通道往返更明显。大文件仍要按架构文档评估 QUIC/TCP，不要假设 DataChannel 能吃满链路。
- 桌面 DataChannel 即使标成 ordered，帧仍可能乱序或少一块。文件改成「先等 file-start-ack，再送 `WSP1` + 序号 + 载荷」，缺的序号用 `file-nak` 重传。不要靠「文件头之前先到的块」来补洞。
- `flutter_webrtc` 1.6.3 没有改本机 ICE agent 优先级的接口。改写发出去的 priority 只影响对端看到的优先级。真正把局域网排到 ZeroTier 前面的是候选门闩：先只发局域网 host，没有局域网才发 ZeroTier，连通后封住。ZeroTier 网卡（Linux `zt*`，Windows 描述里的 ZeroTier）的分类和这套门闩有单元测试。这台机器没有 ZeroTier，所以「局域网和 ZeroTier 同时存在时选谁」还没有在真网上打过。
- 桌面 C++ observer 只有 `OnStateChange` 和 `OnMessage`，没有 `OnBufferedAmountChange`（`flutter_webrtc` 1.6.3 的 `common/cpp`）。`onBufferedAmountLow` 不会响。发送端每攒够约 1 MiB 就轮询 `getBufferedAmount()`。
- 没有 PulseAudio/PipeWire 设备时，libwebrtc 在 `adm_helpers.cc` 里直接 `Abort`（`adm->Init()` 失败），Dart 抓不到。Linux 上要有可用的音频服务，光有数据通道也不行。
- DTLS-SRTP 保持默认开启，配置里没有 `DtlsSrtpKeyAgreement: false`。应用层 E2EE 不在本 spike。没有配置 TURN，中继横幅的代码在，这次没有走到 relay。

### CI

`.github/workflows/webrtc-spike.yml` 会跑信令测试、`flutter analyze` / `flutter test`，并上传 Windows 与 Linux 的 release 构建目录。这些还不是安装包。workflow 不会部署 Worker。
