#!/usr/bin/env bash
# 把任务分发给 Codex：在独立 worktree 中非交互运行，输出落盘。
# 用法: scripts/agent/dispatch.sh <task-id> [-m <model>]
# 若上次门禁失败，会自动把 gate.log 的失败输出附到 prompt 里。
source "$(dirname "$0")/lib.sh"
task_init "${1:-}"; shift || true
require_task

MODEL_ARGS=()
while getopts "m:" opt; do
  case "$opt" in m) MODEL_ARGS=(-m "$OPTARG");; *) exit 2;; esac
done

# 首次分发：从当前 HEAD 建 worktree。spec 和验收测试必须已提交，否则 worktree 里看不到。
if [[ ! -d "$WT" ]]; then
  if [[ -n "$(git -C "$ROOT" status --porcelain -- tasks/"$TASK_ID" gates scripts/agent test)" ]]; then
    echo "tasks/$TASK_ID、gates、scripts/agent 或 test 下有未提交改动，请先提交再分发" >&2; exit 2
  fi
  BASE="$(git -C "$ROOT" rev-parse HEAD)"
  git -C "$ROOT" worktree add -q "$WT" -b "$BRANCH" "$BASE"
  state_set base "$BASE" branch "$BRANCH"
  # Codex 沙箱内无网络，依赖在分发前装好
  (cd "$WT" && flutter pub get >/dev/null)
fi

PROMPT="$TASK_DIR/prompt.md"
{
  cat "$TASK_DIR/spec.md"
  printf '\n## 允许修改的文件\n\n只能修改下列路径，其它文件一律不要动（尤其是 gates/、scripts/agent/、tasks/、.github/ 和未列出的测试）：\n\n'
  grep -vE '^\s*(#|$)' "$TASK_DIR/allowed_paths" | sed 's/^/- /'
  printf '\n## 工作方式\n\n- 当前目录就是你的工作区，直接修改文件，不要提交 git。\n- 完成后自行运行验收命令确认。\n- 最后用几句话总结：改了哪些文件、为什么、验收命令的结果。\n'
  if [[ "$(state_get status)" == "gate_failed" && -f "$TASK_DIR/gate.log" ]]; then
    printf '\n## 上一次提交未通过验收门禁\n\n门禁原始输出如下，请据此修正：\n\n```text\n'
    tail -n 120 "$TASK_DIR/gate.log"
    printf '```\n'
  fi
} > "$PROMPT"

state_bump
state_set status running assignee "codex"
ATTEMPT="$(state_get attempts)"
echo "[dispatch] $TASK_ID 第 $ATTEMPT 次，worktree=$WT"

set +e
codex exec -C "$WT" -s workspace-write "${MODEL_ARGS[@]}" \
  -o "$TASK_DIR/worker-last.md" - < "$PROMPT" > "$TASK_DIR/worker.log" 2>&1
RC=$?
set -e

commit_worktree "task/$TASK_ID: attempt $ATTEMPT (codex)"

if (( RC != 0 )); then
  state_set status worker_error
  echo "[dispatch] codex 退出码 $RC，详见 tasks/$TASK_ID/worker.log" >&2
  exit "$RC"
fi
state_set status awaiting_gate
echo "[dispatch] 完成。摘要: tasks/$TASK_ID/worker-last.md；下一步: gates/run.sh $TASK_ID"
