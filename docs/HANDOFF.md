# 交接说明（2026-11-13，1.0.4）

给接手的 Agent。先读根目录的 `CLAUDE.md`（工作方式和检查命令），再读这份。

## 目标

做完 `docs/prd.md` 里的 MVP。五个里程碑：

| # | 内容 | 状态 |
| --- | --- | --- |
| 1 | 中继、配对、端到端加密文本 | 已合并 |
| 2 | 本地历史与 7 天保留 | 已合并 |
| 3 | 语音通话 + TURN | 已合并；跨机器验收留给用户自己做 |
| 4 | 文件：先做经 R2 中转（≤100 MiB），再做大文件直传 | 已合并（中转已部署；大文件直传 PR #30；端到端验收留给用户） |
| 5 | 打包发布 | 发布流程已在本 PR 完成（填密钥、打 tag 即可出安装包；不要由 Agent 打 tag 或填密钥） |

## 现在在哪

里程碑 1–4 的代码已在 `main` 上合并，`v1.0.1` 已发布。中转文件已部署（`whisper-files` 桶 + Worker `whisper-relay`）。`/turn-credentials` 鉴权已随之后的 Worker 部署生效。语音、中转文件、大文件直传的端到端验收留给用户在两台电脑上做。

`v1.0.1` 已发布。1.0.2（`1.0.2+3`，PR #36 / #37）已合并但未打 tag：Windows 标题乱码、顶部通话栏、在线直传/离线确认中转、通话/来信提示音，以及一次未能解决 Ubuntu→Windows 单向无声的尝试。

1.0.3（当前 `1.0.3+5`，未发版）在 #38 里做了通话诊断、单实例、关到托盘、未读角标、粘贴图片和「关于」。#38 合入后发现 Ubuntu 托盘菜单是空的：tray_manager 在 Linux 上没有实现 `setToolTip`，1.0.3 在 `setIcon` 之后调用它会抛错，`setContextMenu` 根本没跑（本机已确认 `ubuntu-appindicators@ubuntu.com` 已启用，托盘图标和 `/opt/whisper/.../whisper.png` 路径都在，但 DBusMenu 是空根节点）。已改成提示失败不影响菜单注册。GNOME Dock 右键通过 `.desktop` 的 Actions 提供「显示」「退出」；`whisper --quit` 会转到已有进程真正退出（不再只是关到托盘）。不要由 Agent 打 tag 或发布。

1.0.4（`1.0.4+6`，2026-11-13，分支 `fix/linux-tray-menu-and-dock-quit`）修复：

- 点语音通话闪退：1.0.3 加的 `Helper.ensureAudioSession()` 只有 iOS 实现；桌面端 flutter_webrtc 收到没有参数的未知方法，会在 `HandleFrameCryptorMethodCall` 里抛 `std::bad_variant_access`，进程直接终止（`/var/crash` 的转储调用栈为证）。已删掉这两处调用。**桌面端不要调用 flutter_webrtc 里没有原生实现的方法**，Dart 的 try/catch 接不住。验证：只依赖 flutter_webrtc 的临时工程里，修复前必崩，修复后两个 `WebRtcCallMedia` 能连通。
- 新消息不闪：原来只闪窗口的任务栏按钮，关到托盘后窗口是隐藏的，Wayland 下 GTK 紧急提示也无效。现在窗口不在前台时托盘图标在普通图标和带红点图标之间闪（`TrayBlinker`），窗口回到前台就停。
- 粘贴的图片像文件：接收方原来要点接受并选保存位置。现在不超过 20 MiB 的图片（直传和中转）自动收到应用数据目录的 `chat-images/`，气泡里只显示图片；粘贴的图片也存到这里而不是系统临时目录。目录随 7 天保留期清理，清除全部数据时删掉。
- 本机缺 `libgstreamer1.0-dev`，`flutter build linux` 过不了 CMake（audioplayers 需要），所以托盘闪烁和图片显示没有在真实窗口里看过，只有单元测试；需要用户装包后构建或用 CI 产物验证。两台电脑对打的单向无声也还没复测。

音频调查（本机 Ubuntu，2026-11-12 21:55 亚洲/上海）：PipeWire 默认麦克风用 `pw-record` 两秒峰值 648、有效值 154.7，硬件采集正常。独立的 flutter_webrtc 1.6.3 进程内双 `RTCPeerConnection` 环回（不接渲染器、远端 track 关闭以免外放）结果是 `linux-capture=NONZERO`：4 秒内 `bytesSent` 从 928 增到 7263（增量 6335），本端 `audioLevel` 约 0.009–0.011，`totalAudioEnergy` 持续上升。因此 Ubuntu 侧 getUserMedia / 发送在本机是通的，1.0.2 的“Linux 采集没起来”假设不成立。更可能仍是 Windows 远端播放：`SetPlayoutDevice` 默认不会在 getUserMedia 里调用（#2006/#2001），`enumerateDevices` 有时是空的（#2141），`onTrack.streams` 在 Unified Plan 下可能为空。1.0.3 仍补了显式 `sourceId`/`deviceId`、`selectAudioInput` + `selectAudioOutput`（失败时再试 `'default'`）、`ensureAudioSession`、隐藏的本端+远端渲染器、streams 为空时自行建流挂轨，以及通话条上的收发诊断（本端↑字节/电平，远端↓字节/电平）。下次对打时请看这一行：若 Ubuntu 的「本端↑」字节几乎不动，问题在 Ubuntu 发送；若 Ubuntu「本端↑」在涨而 Windows「远端↓」不动或电平一直是 0，问题在 Windows 接收/播放。

分支 `feat/pairing-dialog-autostart`（2026-11-13，未发版、未在真机上验证）：

- Ubuntu→Windows 单向无声：用户确认通话条两边字节都在涨、Windows 有多个输出设备。原因是 Windows 上设备名里没有 default，枚举顺序也和默认设备无关，`pickDefaultPlayoutDeviceId` 退到“第一个输出设备”，声音被送到别的设备。现在 Windows runner 通过 `whisper/desktop` 通道的 `defaultAudioDevices` 报告系统默认播放/录音端点 ID，Dart 按 ID 匹配；匹配不到时不指定设备（不再取第一个）。通话条那行诊断的悬停提示里会显示实际播放设备。Windows 原生代码本机编不了，要靠 CI 和两台电脑对打确认。
- 托盘图标不闪：最小工程实测（本机 GNOME Wayland）窗口隐藏后定时器照常跑、每拍都发出 `NewIcon`，所以 1.0.4 其实在换图，只是“普通图标 ↔ 带红点图标”差别太小。改成“带红点图标 ↔ 空白图标”，回到前台恢复普通图标。屏幕上的实际效果没看到（Wayland 不让截图）。
- 添加联系人改成对话框（`showPairingDialog`），入口只留右上角一个按钮，去掉右下角悬浮按钮。不能用 `AlertDialog`：它要算固有宽度，二维码控件不支持。
- 「关于」里加了开机自动启动开关（`lib/desktop/autostart.dart`）：Linux 写 `~/.config/autostart/whisper.desktop`，Windows 用 `reg` 写当前用户的 `Run` 项；开关状态直接读系统。自启动时窗口正常显示，没有做“启动后藏到托盘”。
- 本机较新的 libayatana 把 `app_indicator_new` 标成弃用，tray_manager 在 `-Werror` 下编不过（CI 的 ubuntu-latest 不受影响）；加上之前缺 `libgstreamer1.0-dev`，本机仍然构建不了 Linux 包。

早期验证代码已清理（PR #31），可执行文件正式名为 `whisper`。不要由 Agent 部署，也不要建新的云资源。`spike/` 目录不要改。

里程碑 5 的打包与发布流程已在 `main`。打 `v*` 标签即可由 GitHub Actions 构建 Linux（deb / AppImage / tar.gz）和 Windows（未签名安装器 + 便携 zip），生成 `SHA256SUMS` 和 `SHA256SUMS.asc` 并创建 GitHub Release。步骤见 `docs/release.md`。不要由 Agent 打 tag 或创建 Release。

检查基线（2026-11-13）：`flutter analyze --no-fatal-infos lib test` 13 条 info；`flutter test` 439 个全过。`worker/` 若未改则不必重跑。

## 之后的事

- `v1.0.1` 已发布；`v1.0.0` 标签因发布流程问题未产出 Release，保留不动。1.0.2 / 1.0.3 都等用户确认后再打 tag，不要由 Agent 打 tag 或发版。Windows 安装包未签名，需按文档通过 SmartScreen。
- 直传的遗留（见 `docs/file-direct.md` 文末）：断点续传、暂停/继续、接收前磁盘空间检查、多通道并行。同一时刻仍只能进行一次直传（第二个文件会 `busy`）。
- 「关于」对话框会显示运行时版本，并给出 GitHub Releases 下载地址，但不会自动检查是否有新版本。
- 语音：请在 Ubuntu↔Windows 上再打一通，对照通话条诊断判断是发送还是 Windows 播放问题。同时确认：第二次启动会唤起已有窗口；点关闭进托盘，顶栏托盘图标左/右键能看到「显示」「退出」，Dock 右键也有这两项，「退出」会真正结束进程；隐藏时来信会闪任务栏；联系人未读角标；Ctrl+V 粘贴图片会当文件发出并在气泡里显示缩略图；联系人页右上角「关于」能看到版本和下载链接。
- 远端有两个已合并的分支没删：`chore/retire-agent-pipeline`、`feat/file-relay-foundation`，留给用户处理。

## 规矩

用户说中文，回复用中文。

- 实现任务直接做，不要分发给别的模型，也不要再提多 Agent 流水线（已封存在 `~/sources/agent-pipeline`，原因见那里的 `archive/README.md`）。
- `main` 受保护。改动走分支和 PR；**推送、开 PR、合并、部署，每一次都先问用户**，之前某次的同意不能沿用。不要开自动合并。
- 花钱的或不可逆的操作（建 R2 桶、部署 Worker、删远端分支）先问。
- 不要碰 Cloudflare 上已有的另一个应用“清谈”（Worker 和桶名是 `tommydeng-chat`，域名 `chat.tommydeng.org`）。
- 密钥、令牌、密码：不要打印到对话里，不要自己往任何输入框或命令里填，由用户自己去 Cloudflare / GitHub 填。查 Worker 的 secret 只列名字。查 `/turn-credentials` 不要打印凭据。
- `worker/.dev.vars` 是本机的密钥文件，不入库、不打印。`~/.codex/config.toml` 里有内联的令牌，不要读也不要打印。
- 应用和 Worker 的代码不记录消息内容、消息 ID、SDP、候选地址、密钥、凭据、文件 ID。
- 提交信息末尾加 `Co-Authored-By: Claude <noreply@anthropic.com>`；PR 描述末尾加 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。

## 容易踩的坑

- `npx wrangler types` 会把本机 `.dev.vars` 里的变量名写进 `worker/worker-configuration.d.ts`。跑完用 `git checkout worker/worker-configuration.d.ts` 还原。
- CI 有四个任务（signaling、flutter-test、build-linux、build-windows）。build-linux 偶尔因为运行器装系统库时域名解析失败而挂，和改动无关，`gh run rerun <id> --failed` 重跑即可。
- 早期验证用的 `FileTransferService`（以及 `lib/files/files.dart`、`lib/transfer/*`）已经删掉。新代码不要再引入这个名字。文件功能走 `FileShareService`。
- 一次 `db.execute` 只放一条 SQL 语句。改表结构在 `AppDatabase._ensureSchema` 里做成幂等的，并把 `schemaVersion` 加一。
- 测试不访问外网：消息用 `test/relay/fake_relay.dart`，文件用 `test/files/fake_file_relay.dart`，直传用 `test/files/fake_file_link.dart` 和 `test/files/fake_file_direct_transport.dart`，HTTP 客户端对着本机回环上的 `HttpServer` 测。

## 文档索引

`docs/prd.md` 需求；`docs/architecture.md` 和 `docs/decisions.md` 架构与取舍；`docs/relay-protocol.md` 中继协议；`docs/message-format.md` 消息格式；`docs/pairing-payload.md` 配对；`docs/call-signaling.md` 通话信令；`docs/local-storage.md` 本地存储；`docs/file-relay.md` 文件中转；`docs/file-direct.md` 大文件直传；`docs/release.md` 发布与校验。
