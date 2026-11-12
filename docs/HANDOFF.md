# 交接说明（2026-11-12）

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

1.0.2 仍未发版（版本号保持 `1.0.2+3`）。已合并的修复：Windows 窗口标题乱码；Ubuntu→Windows 单向无声（隐藏远端 `RTCVideoRenderer`、显式选择默认扬声器、界面显示本端麦克风电平——**两边能否互相听见，仍需用户在两台电脑上再打一通确认**）；呼入/呼出/等待提示音。本分支再补三项使用中的改动：通话改为窗口顶部不挡聊天的栏/来电横幅；双方在线时文件一律直传，离线或直连失败须确认后才走中转（≤100 MiB）；对方来信/来文件有提示音（自己发出的不响；通话进行中不响；窗口在前台且正看着该会话时不响）。不要由 Agent 打 tag 或发布。

早期验证代码已清理（PR #31），可执行文件正式名为 `whisper`。不要由 Agent 部署，也不要建新的云资源。`spike/` 目录不要改。

里程碑 5 的打包与发布流程已在 `main`。打 `v*` 标签即可由 GitHub Actions 构建 Linux（deb / AppImage / tar.gz）和 Windows（未签名安装器 + 便携 zip），生成 `SHA256SUMS` 和 `SHA256SUMS.asc` 并创建 GitHub Release。步骤见 `docs/release.md`。不要由 Agent 打 tag 或创建 Release。

检查基线（本分支）：`flutter analyze --no-fatal-infos lib test` 13 条 info；`flutter test` 393 个。`worker/` 若未改则不必重跑。

## 之后的事

- `v1.0.1` 已发布；`v1.0.0` 标签因发布流程问题未产出 Release，保留不动。1.0.2 等用户确认后再打 tag，不要由 Agent 打 tag 或发版。Windows 安装包未签名，需按文档通过 SmartScreen。
- 直传的遗留（见 `docs/file-direct.md` 文末）：断点续传、暂停/继续、接收前磁盘空间检查、多通道并行。同一时刻仍只能进行一次直传（第二个文件会 `busy`）。
- 应用内检查 GitHub Releases 新版本尚未做。
- 语音：1.0.2 的单向无声修复需要在 Ubuntu↔Windows 上各呼一次，确认两边都能听见；并确认通话中仍能输入文字和发文件、呼入/呼出提示音、来信提示音。文件路径（在线直传、离线确认后中转）的跨机器验收留给用户。
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
