# Whisper

Flutter 桌面客户端（`lib/`、`test/`）+ Cloudflare Worker 信令服务（`worker/`）。`spike/` 是早期验证代码，不参与检查。

常用命令：`flutter analyze --no-fatal-infos lib test`、`flutter test`；`worker/` 下 `npm run typecheck`、`npm test`。

## 工作方式

实现类任务由 Claude Code 直接做，不分发给下级模型。

- 完成与否看检查命令的退出码：上面的常用命令全过才算完成；改了 `worker/` 就跑 worker 的检查。
- 先把可检查的要求写清楚再动手；实现时发现需求有歧义，回头改需求文档。
- `main` 受保护：改动走分支和 PR，推送、开 PR、合并、部署都等用户确认。

多 Agent 流水线（Claude 编排、Codex 实现）已在 2026-11-11 封存到 `~/sources/agent-pipeline`，原因和数据见那里的 `archive/README.md`。
