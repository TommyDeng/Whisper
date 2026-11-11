# 任务：实现会话中继 SessionDO（密文转发 + 离线队列）

## 目标

`worker/` 是一个 Cloudflare Worker。`worker/src/session.ts` 里的 `SessionDO` 目前是占位实现（一律返回 501）。把它实现成协议文档 **`docs/relay-protocol.md` 的“通用规则”和“一、会话中继 SessionDO”** 所描述的 Durable Object：两个固定身份（`a`、`b`）的客户端通过 WebSocket 互发不透明的密文；对方不在线时消息持久化排队，对方确认（ack）后删除，最长保留 7 天。

协议文档是唯一的行为依据，请先完整读一遍。验收测试 `worker/test/session.spec.ts` 已经写好，逐条对应文档。

## 相关文件

- `docs/relay-protocol.md`：协议（必读）。
- `worker/src/session.ts`：**唯一要改的文件**。
- `worker/src/relay_limits.ts`：常量和 `isExpired`，直接 import 使用，不要改、不要在别处重复定义数值。
- `worker/src/index.ts`：入口。已经校验了 `sessionId`、`peer` 和 Upgrade 头，然后把原始请求交给 `env.SESSIONS`；所以 DO 的 `fetch` 收到的一定是 `/session/<id>?peer=a|b` 的 WebSocket 升级请求，从 URL 的查询参数读 `peer`。
- `worker/src/room.ts`：已有的另一个 DO，可以参考它怎么用 WebSocket Hibernation API（`WebSocketPair`、`ctx.acceptWebSocket`、`serializeAttachment`、`webSocketMessage`、`webSocketClose`）。注意它的离线消息逻辑有缺陷，不要照抄那部分。
- `worker/test/session.spec.ts`、`worker/test/helpers.ts`：验收测试。

## 具体要求

- 完整实现文档“通用规则”和第一节的全部行为，包括：welcome / 在线状态通知、`msg` 入队与转发、`ephemeral`、`ack` 与 `delivered`、各种校验错误、同一 peer 重连时替换旧连接（关闭码 4001）、限速、存储布局、过期清理与 alarm。
- 存储布局必须与文档一致（键 `q:<peer>:<12 位序号>`，值 `{id, payload, ts}`），测试会直接读写存储。投递和清理都要按前缀 `list`，不能假设存储里只有自己写入的序号。
- 连接身份（peer、限速计数等）放在 WebSocket 的 attachment 里；DO 可能在两帧之间休眠，不能依赖内存里的 Map 保存必须的状态。
- 转发给对方的帧只包含文档列出的字段，客户端多带的字段不转发。
- TypeScript 严格模式下通过类型检查，不用 `any` 绕过。

## 环境与验收

工作目录是仓库根目录，中继代码在 `worker/`。先装依赖：

```bash
cd worker && npm ci && npx wrangler types
```

验收命令（都在 `worker/` 下执行）：

- `npm run typecheck` 无错误
- `npx vitest run test/session.spec.ts` 全部通过
- `npm test` 全部通过（包括原有的 `test/signaling.spec.ts`、`test/protocol.spec.ts`）

说明：

- `worker/src/invite.ts` 里的 `InviteDO` 也是占位实现，由后续任务完成，不要去实现它。
- 如果 wrangler 或 vitest 因为写不了 `~/.config` 而启动失败，在命令前加 `XDG_CONFIG_HOME=/tmp/whisper-xdg`。
- 测试跑不起来时不要猜：至少保证 `npm run typecheck` 通过，并对照协议文档和测试文件逐条核对实现。

## 不要做

- 不要修改 allowed_paths 以外的任何文件，包括 `worker/src/index.ts`、`worker/src/relay_limits.ts`、`worker/wrangler.jsonc`、`worker/worker-configuration.d.ts` 和 `worker/test/` 下的所有文件。
- 不要新增依赖。
- 不要写日志（`console.log` 等）。
