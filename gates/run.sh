#!/usr/bin/env bash
# 门禁入口：依次运行范围门禁和功能门禁，输出写入 tasks/<id>/gate.log，并更新任务状态。
# 用法: gates/run.sh <task-id>    退出码 0=全部通过
#
# 门禁脚本始终从主检出运行，worktree 里的 gates/ 副本不会被执行，
# 所以下级即使改了它们也不影响判定（同时会被范围门禁拦下）。
source "$(dirname "$0")/../scripts/agent/lib.sh"
task_init "${1:-}"
require_task
[[ -d "$WT" ]] || { echo "worktree 不存在，任务尚未分发: $WT" >&2; exit 2; }

commit_worktree "task/$TASK_ID: uncommitted changes before gate"

LOG="$TASK_DIR/gate.log"
HERE="$ROOT/gates"
RC=0
{
  echo "### gate run $(date -Is)  task=$TASK_ID  head=$(git -C "$WT" rev-parse --short HEAD)"
  echo "--- scope ---"
  bash "$HERE/scope.sh" "$TASK_ID" || RC=1
  if (( RC == 0 )); then
    echo "--- functional ---"
    bash "$HERE/functional.sh" "$TASK_ID" || RC=1
  fi
  echo "### result: $([[ $RC == 0 ]] && echo PASS || echo FAIL)"
} > "$LOG" 2>&1 || true

if (( RC == 0 )); then
  state_set status review
  echo "[gate] PASS  →  下一步：跨模型审查，然后由用户确认合并"
else
  state_set status gate_failed
  echo "[gate] FAIL（第 $(state_get attempts) 次尝试）详见 tasks/$TASK_ID/gate.log" >&2
  tail -n 25 "$LOG" >&2
fi
exit "$RC"
