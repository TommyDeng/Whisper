#!/usr/bin/env bash
# 把任务分发给 Codex：在独立 worktree 中非交互运行，输出落盘。
# 用法: scripts/agent/dispatch.sh <task-id> [-p <profile>] [-m <model>]
# 模型默认按 scripts/agent/models.conf 和 tasks/<id>/tier 自动选择；给了 -m 或 -p 则完全按手动指定。
# 若上次门禁失败，会自动把 gate.log 的失败输出附到 prompt 里。
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/models.conf"
load_conf
task_init "${1:-}"; shift || true
require_task

MANUAL_ARGS=()
while getopts "m:p:" opt; do
  case "$opt" in
    m) MANUAL_ARGS+=(-m "$OPTARG");;
    p) MANUAL_ARGS+=(-p "$OPTARG");;
    *) exit 2;;
  esac
done

TIER="$(tr -d '[:space:]' < "$TASK_DIR/tier" 2>/dev/null || true)"
TIER="${TIER:-logic}"
EFFORT_VAR="EFFORT_$TIER"
TIMEOUT_VAR="WORKER_TIMEOUT_$TIER"
[[ -n "${!EFFORT_VAR:-}" && -n "${!TIMEOUT_VAR:-}" ]] || { echo "tasks/$TASK_ID/tier 的值无效: $TIER（应为 mechanical 或 logic）" >&2; exit 2; }
EFFORT="${!EFFORT_VAR}"
WORKER_TIMEOUT="${!TIMEOUT_VAR}"

PRIMARY_ARGS=(-p "$PRIMARY_PROFILE" -m "$PRIMARY_MODEL" -c "model_reasoning_effort=$EFFORT")
FALLBACK_ARGS=(-c "model_provider=$FALLBACK_PROVIDER" -m "$FALLBACK_MODEL" -c "model_reasoning_effort=$EFFORT")

# 首次分发：从当前 HEAD 建 worktree。spec 和验收测试必须已提交，否则 worktree 里看不到。
if [[ ! -d "$WT" ]]; then
  CLEAN_PATHS=("tasks/$TASK_ID" gates scripts/agent agent.conf "${DISPATCH_CLEAN_PATHS[@]}")
  if [[ -n "$(git -C "$ROOT" status --porcelain -- "${CLEAN_PATHS[@]}")" ]]; then
    echo "以下路径有未提交改动，请先提交再分发: ${CLEAN_PATHS[*]}" >&2; exit 2
  fi
  BASE="$(git -C "$ROOT" rev-parse HEAD)"
  git -C "$ROOT" worktree add -q "$WT" -b "$BRANCH" "$BASE"
  state_set base "$BASE" branch "$BRANCH"
  # 沙箱内可能没有网络，依赖在分发前装好
  if [[ -n "$SETUP_CMD" ]]; then
    (cd "$WT" && bash -euo pipefail -c "$SETUP_CMD") > "$TASK_DIR/setup.log" 2>&1 \
      || { echo "准备命令失败，详见 tasks/$TASK_ID/setup.log" >&2; exit 2; }
  fi
fi
state_mark_once dispatched_at

PROMPT="$TASK_DIR/prompt.md"
{
  cat "$TASK_DIR/spec.md"
  printf '\n## 允许修改的文件\n\n只能修改下列路径，其它文件一律不要动（尤其是 %s 和未列出的测试）：\n\n' "${PROTECTED[*]}"
  grep -vE '^\s*(#|$)' "$TASK_DIR/allowed_paths" | sed 's/^/- /'
  printf '\n## 工作方式\n\n- 当前目录就是你的工作区，直接修改文件，不要提交 git。\n- 只实现说明要求的行为。如果验收测试看起来自相矛盾或本身有错，不要用绕过的写法让它通过，在总结里指出来。\n- 完成后自行运行验收命令确认。%s\n- 最后用几句话总结：改了哪些文件、为什么、验收命令的结果。\n' "$WORKER_HINTS"
  if [[ "$(state_get status)" == "gate_failed" && -f "$TASK_DIR/gate.log" ]]; then
    printf '\n## 上一次提交未通过验收门禁\n\n门禁原始输出如下，请据此修正：\n\n```text\n'
    tail -n 120 "$TASK_DIR/gate.log"
    printf '```\n'
  fi
} > "$PROMPT"

state_bump
ATTEMPT="$(state_get attempts)"

# 主力最近失败过：冷却期内直接用备选，不再白等
COOLDOWN_FILE="$(runtime_dir)/primary-failed-at"
primary_cooling() {
  [[ -f "$COOLDOWN_FILE" ]] || return 1
  (( $(date +%s) - $(cat "$COOLDOWN_FILE") < PRIMARY_COOLDOWN ))
}

# 选模型：手动指定 > 第 N 次起用备选 > 主力冷却中用备选 > 主力
if (( ${#MANUAL_ARGS[@]} )); then
  MODEL_ARGS=("${MANUAL_ARGS[@]}"); MODEL_LABEL="manual: ${MANUAL_ARGS[*]}"; CAN_FALLBACK=0
elif (( ATTEMPT >= FALLBACK_FROM_ATTEMPT )); then
  MODEL_ARGS=("${FALLBACK_ARGS[@]}"); MODEL_LABEL="$FALLBACK_MODEL"; CAN_FALLBACK=0
elif primary_cooling; then
  MODEL_ARGS=("${FALLBACK_ARGS[@]}"); MODEL_LABEL="$FALLBACK_MODEL (主力冷却中)"; CAN_FALLBACK=0
else
  MODEL_ARGS=("${PRIMARY_ARGS[@]}"); MODEL_LABEL="$PRIMARY_MODEL"; CAN_FALLBACK=1
fi
state_set status running assignee "codex:$MODEL_LABEL" tier "$TIER"
echo "[dispatch] $TASK_ID 第 $ATTEMPT 次，tier=$TIER effort=$EFFORT model=$MODEL_LABEL"

# 下级的权限（只作用于本次调用，不改 ~/.codex/config.toml）：
# - 沙箱：只能写任务 worktree；放开网络，否则很多测试建不了本地 socket。
#   不用 danger-full-access：那样下级能改主检出里的 gates/ 和 tasks/，门禁就不可信了。
# - 额外可写目录和其它参数来自 agent.conf。
CODEX_ARGS=(-s workspace-write -c sandbox_workspace_write.network_access=true)
for dir in "${SANDBOX_WRITABLE_DIRS[@]}"; do
  [[ -d "$dir" ]] && CODEX_ARGS+=(--add-dir "$dir")
done
CODEX_ARGS+=("${CODEX_EXTRA_ARGS[@]}")

LOG="$TASK_DIR/worker.log"

run_codex() {
  timeout "$WORKER_TIMEOUT" codex exec -C "$WT" "${CODEX_ARGS[@]}" "$@" \
    -o "$TASK_DIR/worker-last.md" - < "$PROMPT" >> "$LOG" 2>&1 &
  local pid=$!
  # 看门狗：日志长时间没有新内容就判定卡死，中止这次调用
  (
    while kill -0 "$pid" 2>/dev/null; do
      sleep "${WATCHDOG_INTERVAL:-30}"
      if (( $(date +%s) - $(stat -c %Y "$LOG") > WORKER_IDLE_TIMEOUT )); then
        echo "[dispatch] 下级超过 ${WORKER_IDLE_TIMEOUT}s 没有输出，判定卡死并中止" >> "$LOG"
        kill "$pid" 2>/dev/null
        break
      fi
    done
  ) &
  local watchdog=$!
  local rc=0
  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

: > "$LOG"
rm -f "$TASK_DIR/worker-last.md"
RC=0
run_codex "${MODEL_ARGS[@]}" || RC=$?
# 主力调用失败（限流、服务报错、超时、卡死）：同一次分发内改用备选，不增加尝试次数
if (( RC != 0 && CAN_FALLBACK )); then
  date +%s > "$COOLDOWN_FILE"
  echo "[dispatch] $MODEL_LABEL 调用失败（退出码 $RC），改用备选 $FALLBACK_MODEL；主力进入冷却" | tee -a "$LOG" >&2
  # 丢掉主力留下的半成品，备选从干净的状态开始
  git -C "$WT" reset -q --hard && git -C "$WT" clean -qfd
  MODEL_LABEL="$FALLBACK_MODEL (主力失败后接手)"
  state_set assignee "codex:$MODEL_LABEL"
  RC=0
  run_codex "${FALLBACK_ARGS[@]}" || RC=$?
elif (( RC == 0 && CAN_FALLBACK )); then
  rm -f "$COOLDOWN_FILE"
fi

commit_worktree "task/$TASK_ID: attempt $ATTEMPT ($MODEL_LABEL)"

if (( RC != 0 )); then
  state_set status worker_error
  echo "[dispatch] codex 退出码 $RC，详见 tasks/$TASK_ID/worker.log" >&2
  exit "$RC"
fi
state_set status awaiting_gate
echo "[dispatch] 完成。摘要: tasks/$TASK_ID/worker-last.md；下一步: gates/run.sh $TASK_ID"
