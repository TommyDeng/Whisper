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
| 5 | 打包发布 | 未开始 |

## 现在在哪

里程碑 1–4 的代码已在 `main` 上合并。中转文件已部署（`whisper-files` 桶 + Worker `whisper-relay`）。语音、中转文件、大文件直传的端到端验收留给用户在两台电脑上做。

本 PR（分支 `chore/retire-spike-code`）清理早期验证代码，并把可执行文件 / 窗口标题 / 健康检查改成正式名「耳语 / whisper」。`/turn-credentials` 改为复用文件接口的会话身份鉴权（该 peer 须当前在线）。**合并后需要重新部署 Worker，鉴权才会在线上生效**；本 PR 不部署、不建云资源。`spike/` 目录未改，也不要改。

本 PR 检查：`flutter analyze --no-fatal-infos lib test` 13 条 info（不超过 18），无 warning/error；`flutter test` 369 个全过；`worker/` 下 `npm run typecheck` 通过、`npm test` 77 个。

## 之后的事

- 里程碑 5：发布。GPG 等密钥由用户自己在 GitHub Actions 里填。
- 直传的遗留（见 `docs/file-direct.md` 文末）：断点续传、暂停/继续、接收前磁盘空间检查、多通道并行；以及把 ≤100 MiB 且直连可用的文件也改走直传（产品文档里的“直连优先”）。
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

`docs/prd.md` 需求；`docs/architecture.md` 和 `docs/decisions.md` 架构与取舍；`docs/relay-protocol.md` 中继协议；`docs/message-format.md` 消息格式；`docs/pairing-payload.md` 配对；`docs/call-signaling.md` 通话信令；`docs/local-storage.md` 本地存储；`docs/file-relay.md` 文件中转；`docs/file-direct.md` 大文件直传。
