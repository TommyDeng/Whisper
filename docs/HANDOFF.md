# 交接说明（2026-11-12）

给接手的 Agent。先读根目录的 `CLAUDE.md`（工作方式和检查命令），再读这份。

## 目标

做完 `docs/prd.md` 里的 MVP。五个里程碑：

| # | 内容 | 状态 |
| --- | --- | --- |
| 1 | 中继、配对、端到端加密文本 | 已合并 |
| 2 | 本地历史与 7 天保留 | 已合并 |
| 3 | 语音通话 + TURN | 已合并；跨机器验收留给用户自己做 |
| 4 | 文件：先做经 R2 中转（≤100 MiB），再做大文件直传 | **进行中**，见下 |
| 5 | 打包发布 | 未开始 |

## 现在在哪

- 分支 `feat/file-relay-client`，从 `main`（`95f523e`）切出，**只在本地，没有推送，没有 PR**。
- 工作区干净。检查结果：`flutter analyze --no-fatal-infos lib test` 18 条 info（基线，全是旧代码的，不能增加）；`flutter test` 331 个全过。这个分支没有改 `worker/`。
- `main` 上的基线：Flutter 273 个测试；`worker/` 下 `npm run typecheck` 通过、`npm test` 66 个。

里程碑 4 第一阶段（R2 中转）拆成四个任务，设计和可检查的要求都在 `docs/file-relay.md`：

| 任务 | 内容 | 状态 |
| --- | --- | --- |
| 1 | Worker 文件接口（`worker/src/files.ts`） | 已合并（PR #26） |
| 2 | 客户端分块加密（`lib/files/file_cipher.dart`） | 已合并（PR #26） |
| 3 | 客户端上传下载、`file` 消息类型、本地路径记录 | 做完，在本分支上，待推送和 PR |
| 4 | 界面：选文件、进度、取消、保存 | **未开始，下一步** |

## 任务 3 留下了什么

| 文件 | 作用 |
| --- | --- |
| `lib/files/file_offer.dart` | `FileOffer`：文件消息正文的编解码和校验；`safeName` 处理对方给的不可信文件名 |
| `lib/files/file_relay_api.dart` | `FileRelayApi` 接口和 HTTP 实现 `HttpFileRelay` |
| `lib/files/file_relay_transfer.dart` | `FileRelayTransfer`：上传、断点续传下载、重试、取消（`CancelToken`） |
| `lib/files/file_share_service.dart` | `FileShareService`：给界面用的入口，`AppServices.instance.files` |
| `lib/messaging/messaging_service.dart` | `sendFile`；`ChatMessage.file`；收到的文件消息落库 |
| `lib/storage/` | 数据库 v5：`file_transfers` 表 + 消息删除触发器；`LocalDatabase.setFilePath` / `getFilePaths` |
| `test/files/fake_file_relay.dart` | 内存假中继，任务 4 的测试可以直接用 |

`lib/ui/chat_screen.dart` 目前只有占位：文件消息显示成“[文件] 文件名”。

## 下一步：任务 4（界面）

先把可检查的要求写进 `docs/file-relay.md`（新开“任务 4”一节），再动手。要接的接口都在 `FileShareService`：

- `send(contact, file)`：成功返回消息 ID；失败或取消返回 null，不抛异常，原因在状态里。
- `uploads(sessionId)`：进行中和失败的上传（消息还没生成，所以不在消息列表里，要单独画）。
- `download(contact, message, target)`、`downloadState(msgId)`：下载和它的进度／失败原因。
- `localPaths(sessionId)`：msgId → 本地路径。发出的是源文件，收到的是保存位置；有记录就表示“已保存”。
- `cancel(id)`：取消进行中的传输，或清掉一条失败记录。
- `updates`：有变化时发出 sessionId，界面据此刷新。

失败原因的取值：`too-large`、`network`、`not-found`、`corrupt`、`changed`、`rejected`、`failed`，界面要各给一句人话。

需要先定下来的事（没有现成答案）：

- 选文件和选保存位置用什么。`pubspec.yaml` 里目前没有文件选择的依赖，加依赖前看一下它在 Linux 和 Windows 上的表现。
- 保存时目标已存在怎么办。`FileReceiver.finish` 是直接改名覆盖，重名要由界面在选目标时处理。保存用的文件名用 `offer.safeName`，不要用 `offer.name`。
- 下载完成后中继上的块会被删掉，所以一个文件只能成功下载一次；本地记录丢了（比如换了保存位置又删了文件）就再也下不回来，界面上要说清楚。
- 文件消息不支持阅后即焚：联系人开着阅后即焚时发文件，要么禁用要么提示。

## 之后的事

- **部署前必须补的**：文件上传没有鉴权和配额；R2 桶 `whisper-files` 没建，7 天生命周期规则没配；Worker 的文件接口没部署。
- 里程碑 4 第二阶段：大文件直传。
- 里程碑 5：发布。GPG 等密钥由用户自己在 GitHub Actions 里填。
- 零碎：`/turn-credentials` 没有鉴权，可以加固；早期验证代码还没清（`lib/session/call_controller.dart`、`lib/voice/voice_page.dart`、`lib/files/file_transfer_service.dart`、`lib/files/file_config.dart`、`lib/transfer/*`、健康检查里的 `whisper-webrtc-spike` 字样、可执行文件名）。`spike/` 目录不参与检查，不要改。
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
- `FileTransferService` 这个名字被早期验证代码占了（`lib/files/file_transfer_service.dart`，由 `lib/files/files.dart` 导出）。新代码不要用这个名字，也不要从 `files.dart` 导入。
- 一次 `db.execute` 只放一条 SQL 语句。改表结构在 `AppDatabase._ensureSchema` 里做成幂等的，并把 `schemaVersion` 加一。
- 测试不访问外网：消息用 `test/relay/fake_relay.dart`，文件用 `test/files/fake_file_relay.dart`，HTTP 客户端对着本机回环上的 `HttpServer` 测。

## 文档索引

`docs/prd.md` 需求；`docs/architecture.md` 和 `docs/decisions.md` 架构与取舍；`docs/relay-protocol.md` 中继协议；`docs/message-format.md` 消息格式；`docs/pairing-payload.md` 配对；`docs/call-signaling.md` 通话信令；`docs/local-storage.md` 本地存储；`docs/file-relay.md` 文件中转。
