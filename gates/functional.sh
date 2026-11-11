#!/usr/bin/env bash
# 功能门禁：在任务 worktree 中运行项目检查（agent.conf）和任务自带的 accept.sh。
# 用法: gates/functional.sh <task-id>    退出码 0=通过
source "$(dirname "$0")/../scripts/agent/lib.sh"
load_conf
task_init "${1:-}"
require_task

BASE="$(state_get base)"
cd "$WT"

(( ${#CHECKS[@]} )) || [[ -f "$TASK_DIR/accept.sh" ]] || { echo "agent.conf 的 CHECKS 为空，任务也没有 accept.sh：没有任何检查可跑" >&2; exit 1; }

run_check() {
  echo "== $1 =="
  bash -euo pipefail -c "$1"
}

for check in "${CHECKS[@]}"; do
  run_check "$check"
done

# 条件检查：只有改到匹配路径时才跑。格式 '<路径正则> => <命令>'
CHANGED="$(git -C "$ROOT" diff --name-only "$BASE" "$BRANCH")"
for entry in "${CONDITIONAL_CHECKS[@]}"; do
  pattern="${entry%% => *}"
  command="${entry#* => }"
  [[ "$pattern" != "$entry" ]] || { echo "CONDITIONAL_CHECKS 格式不对（应为 '<路径正则> => <命令>'）: $entry" >&2; exit 1; }
  if grep -qE "$pattern" <<< "$CHANGED"; then
    run_check "$command"
  fi
done

# 任务特有验收：使用主检出里的 accept.sh（下级改不到），在 worktree 中执行
if [[ -f "$TASK_DIR/accept.sh" ]]; then
  echo "== tasks/$TASK_ID/accept.sh =="
  bash "$TASK_DIR/accept.sh"
fi

echo "functional ok"
