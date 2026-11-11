# Whisper

Flutter 桌面客户端（`lib/`、`test/`）+ Cloudflare Worker 信令服务（`worker/`）。`spike/` 是早期验证代码，不参与门禁。

常用命令：`flutter analyze --no-fatal-infos lib test`、`flutter test`；`worker/` 下 `npm run typecheck`、`npm test`。

<!-- agent-pipeline:start -->
## 多 Agent 编排规则

你（Claude Code）是唯一编排者。Codex 是下级实现者，通过脚本调用，不直接与用户交互。项目相关的设置（检查命令、依赖安装等）都在根目录的 `agent.conf`。

### 什么任务走流水线

走流水线：验收标准能写成命令的实现类任务（修 bug、加带测试的功能、重构、清理告警）。

不走流水线，你直接做：探索性问题、界面观感调整、一两行的改动、需要真机或多端联调才能验证的改动。拿不准时直接做，并告诉用户原因。

### 流程

1. **建任务**：`scripts/agent/new-task.sh <task-id>`，然后填写 `tasks/<id>/`：
   - `spec.md`：目标、可检查的要求、验收命令。写给一个没有任何上下文的实现者看，带上相关文件路径。
   - `allowed_paths`：允许修改的路径 glob，尽量窄。
   - `tier`：`mechanical`（清告警、改名、格式调整等不需要设计判断的任务）或 `logic`（修 bug、加功能、重构；默认）。它决定下级的推理强度和时限。
   - `accept.sh`（可选）：本任务特有的验收命令，在 worktree 根目录执行，退出码 0 为通过。
   - 需要新测试来定义行为时，**由你先写好验收测试并提交**，且不把它们放进 `allowed_paths`。每个测试自己建、自己清理用到的对象，不依赖别的测试留下的状态。
2. **提交** spec 和验收测试。
3. **自检**：`scripts/agent/precheck.sh <id>`。验收在没实现时必须失败；看它打印的失败原因，确认是“还没实现”而不是验收自己写错了。
4. **分发**：`scripts/agent/dispatch.sh <id>`，用后台 Bash 运行（可能超过 10 分钟）。它会建 `.worktrees/<id>` 和分支 `task/<id>`。
5. **门禁**：`gates/run.sh <id>`。退出码是唯一的通过信号；不要凭阅读 `worker-last.md` 判断完成。
6. **失败重试**（`state.json` 的 `attempts` 计数）：
   - 第 1 次失败：直接再跑 `dispatch.sh <id>`，它会自动附上 `gate.log`。
   - 第 2 次失败：再跑 `dispatch.sh <id>`，脚本会自动换成备选模型。
   - 第 3 次失败：你自己在 worktree 里接手；仍不过则把状态标为 `blocked`，向用户说明阻塞原因。
7. **审查**：门禁通过后审 `git diff <base> task/<id>`。实现者是 Codex 时由你（或你的子代理）审；实现者是你时运行 `scripts/agent/review.sh <id>` 让 Codex 审。除了对错，专门看一项：**有没有说明里没要求的行为**（多出来的开关、状态、兜底逻辑），有的话弄清它为什么存在——常常是验收测试本身有问题的信号。审查意见只作提示，不阻断，但要如实转述给用户。
8. **合并**：向用户汇总（改动、门禁结果、审查意见、实际用的模型）并**等用户确认**，然后运行 `scripts/agent/finish-task.sh <id>`。它负责合并、清理 worktree 和分支、把状态记为 `merged`、记录本任务的 token 消耗。

### 下级模型

模型、时限都在 `scripts/agent/models.conf`，分发时自动选择，不需要手动传参：

- 主力模型用于前两次尝试；备选模型从第 3 次尝试起使用。
- 主力调用本身失败（报错、超时、长时间没有输出）时，同一次分发内自动换备选接手，不计失败次数；之后一段时间内的分发直接用备选。
- 推理强度和时限由任务的 `tier` 决定。

`dispatch.sh <id> -m <model>`（可加 `-p <profile>`）用于手动指定，仅在用户要求时使用。汇总时写明实际用了哪个模型（见 `state.json` 的 `assignee`）。

### 硬性约束

- 不要为了让门禁通过而修改 `gates/`、`agent.conf`、已有测试或任务的 `accept.sh`。如果门禁或验收测试本身写错了，停下来告诉用户，说明错在哪。
- 门禁脚本只从主检出运行，不运行 worktree 里的副本。
- 只读 `worker-last.md` 和 `gate.log`；`worker.log` 很长，只在排查问题时按需查看。
- 文件范围重叠的任务串行；不重叠的可以并行分发。
- 不要推送 `task/*` 分支。
- `scripts/agent/` 和 `gates/` 由 agent-pipeline 安装，不要在项目里直接改；要改就改上游再重新安装。
<!-- agent-pipeline:end -->
