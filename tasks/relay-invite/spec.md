# 任务：实现配对 InviteDO（一次性邀请、请求与批准的转交）

## 目标

`worker/` 是一个 Cloudflare Worker。`worker/src/invite.ts` 里的 `InviteDO` 目前是占位实现（一律返回 501）。把它实现成协议文档 **`docs/relay-protocol.md` 的“通用规则”和“二、配对 InviteDO”** 所描述的 Durable Object：邀请人登记一个最长 24 小时的一次性邀请；加入者凭邀请发出配对请求；邀请人批准或拒绝；加入者确认后邀请作废。任一方离线时，请求和应答由 DO 暂存，等对方重连时交付。

协议文档是唯一的行为依据，请先完整读一遍。验收测试 `worker/test/invite.spec.ts` 已经写好，逐条对应文档。

## 相关文件

- `docs/relay-protocol.md`：协议（必读）。
- `worker/src/invite.ts`：**唯一要改的文件**。
- `worker/src/relay_limits.ts`：常量，直接 import 使用，不要改、不要在别处重复定义数值。
- `worker/src/index.ts`：入口。已经校验了 `inviteId`、`role`、`key` 的格式和 Upgrade 头，然后把原始请求交给 `env.INVITES`；所以 DO 的 `fetch` 收到的一定是 `/invite/<id>?role=...&key=...` 的 WebSocket 升级请求，从 URL 查询参数读 `role`、`key`、`expires`。`expires` 的校验在 DO 里做。
- `worker/src/room.ts`：已有的另一个 DO，可以参考它怎么用 WebSocket Hibernation API（`WebSocketPair`、`ctx.acceptWebSocket`、`serializeAttachment`、`webSocketMessage`、`webSocketClose`）。
- `worker/test/invite.spec.ts`、`worker/test/helpers.ts`：验收测试。

## 具体要求

- 完整实现文档“通用规则”和第二节的全部行为，包括：登记与 `expires` 校验、升级前的各种 HTTP 拒绝（404 / 410 / 403 / 400，顺序按文档）、welcome 及重连时补发暂存的请求或应答、三种客户端帧的状态流转、错误码及其检查顺序（角色 → 状态 → 字段）、输掉竞争的加入者被 4003 关闭、同角色同 key 重连替换旧连接（4001）、`pair-done` 后用 1000 关闭所有连接并清掉请求和应答内容、限速、过期 alarm（4002 关闭并删除全部存储）。
- 存储布局必须与文档一致（键 `invite`，字段名见文档），测试会直接读写存储。`expiresAt` 是毫秒；alarm 时刻等于 `expiresAt`。
- 被拒绝的登记（`bad-expiry`）不能留下任何存储。
- 连接身份（role、key、限速计数等）放在 WebSocket 的 attachment 里；DO 可能在两帧之间休眠，不能依赖内存保存必须的状态。
- 转发的帧只包含文档列出的字段。
- TypeScript 严格模式下通过类型检查，不用 `any` 绕过。

## 环境与验收

工作目录是仓库根目录，中继代码在 `worker/`。先装依赖：

```bash
cd worker && npm ci && npx wrangler types
```

验收命令（都在 `worker/` 下执行）：

- `npm run typecheck` 无错误
- `npx vitest run test/invite.spec.ts` 全部通过
- `npm test` 全部通过（包括原有的 signaling、protocol、session 测试）

说明：

- `worker/src/session.ts` 里的 `SessionDO` 已经实现并通过测试，可以参考它的写法（Hibernation、attachment、限速），但不要改它。
- 入库的 `worker/worker-configuration.d.ts` 已是最新；`npx wrangler types` 重新生成后如果该文件出现改动，用 `git checkout -- worker/worker-configuration.d.ts` 还原。
- 如果 wrangler 或 vitest 因为写不了 `~/.config` 而启动失败，在命令前加 `XDG_CONFIG_HOME=/tmp/whisper-xdg`。
- 测试跑不起来时不要猜：至少保证 `npm run typecheck` 通过，并对照协议文档和测试文件逐条核对实现。

## 不要做

- 不要修改 allowed_paths 以外的任何文件，包括 `worker/src/index.ts`、`worker/src/relay_limits.ts`、`worker/wrangler.jsonc`、`worker/worker-configuration.d.ts` 和 `worker/test/` 下的所有文件。
- 不要新增依赖。
- 不要写日志（`console.log` 等）。
