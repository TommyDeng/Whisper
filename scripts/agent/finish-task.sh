#!/usr/bin/env bash
# 收尾：把已通过门禁的任务分支合并进当前分支，清理 worktree 和分支，记录状态与编排者的 token 消耗。
# 只在用户确认合并之后运行。
# 用法: scripts/agent/finish-task.sh <task-id>
source "$(dirname "$0")/lib.sh"
task_init "${1:-}"
require_task

STATUS="$(state_get status)"
[[ "$STATUS" == "review" ]] || { echo "任务状态是 $STATUS，不是 review：门禁未通过或已经收尾，不能合并" >&2; exit 2; }
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]] || { echo "主检出有未提交的改动，先提交或还原" >&2; exit 2; }
git -C "$ROOT" rev-parse --verify -q "$BRANCH" >/dev/null || { echo "分支不存在: $BRANCH" >&2; exit 2; }

# 门禁之后任务分支不应再有新提交；有的话要重新过门禁
GATE_HEAD="$(state_get gate_head)"
if [[ -n "$GATE_HEAD" && "$(git -C "$ROOT" rev-parse "$BRANCH")" != "$GATE_HEAD" ]]; then
  echo "任务分支在门禁通过之后又有改动，请重新运行 gates/run.sh $TASK_ID" >&2; exit 2
fi

git -C "$ROOT" merge --no-ff "$BRANCH" -m "合并 $BRANCH（$(state_get assignee)）"
[[ -d "$WT" ]] && git -C "$ROOT" worktree remove "$WT"
git -C "$ROOT" branch -d "$BRANCH"
state_set status merged merged_at "$(date -Is)"
echo "[finish] 已合并 $BRANCH，状态记为 merged"

"$ROOT/scripts/agent/claude-usage.sh" --task "$TASK_ID" || echo "[finish] token 统计失败（不影响合并）" >&2
