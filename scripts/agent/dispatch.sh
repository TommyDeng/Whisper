#!/usr/bin/env bash
# 把任务分发给 Codex：在独立 worktree 中非交互运行，输出落盘。
# 用法: scripts/agent/dispatch.sh <task-id> [-p <profile>] [-m <model>]
# 模型默认按 scripts/agent/models.conf 和 tasks/<id>/tier 自动选择；给了 -m 或 -p 则完全按手动指定。
# 若上次门禁失败，会自动把 gate.log 的失败输出附到 prompt 里。
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/models.conf"
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
[[ -n "${!EFFORT_VAR:-}" ]] || { echo "tasks/$TASK_ID/tier 的值无效: $TIER（应为 mechanical 或 logic）" >&2; exit 2; }
EFFORT="${!EFFORT_VAR}"

PRIMARY_ARGS=(-p "$PRIMARY_PROFILE" -m "$PRIMARY_MODEL" -c "model_reasoning_effort=$EFFORT")
FALLBACK_ARGS=(-c "model_provider=$FALLBACK_PROVIDER" -m "$FALLBACK_MODEL" -c "model_reasoning_effort=$EFFORT")

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
  printf '\n## 工作方式\n\n- 当前目录就是你的工作区，直接修改文件，不要提交 git。\n- 完成后自行运行验收命令确认。依赖已装好，flutter 命令请加 `--no-pub`。\n- 最后用几句话总结：改了哪些文件、为什么、验收命令的结果。\n'
  if [[ "$(state_get status)" == "gate_failed" && -f "$TASK_DIR/gate.log" ]]; then
    printf '\n## 上一次提交未通过验收门禁\n\n门禁原始输出如下，请据此修正：\n\n```text\n'
    tail -n 120 "$TASK_DIR/gate.log"
    printf '```\n'
  fi
} > "$PROMPT"

state_bump
ATTEMPT="$(state_get attempts)"

# 选模型：手动指定 > 第 N 次起用备选 > 主力
if (( ${#MANUAL_ARGS[@]} )); then
  MODEL_ARGS=("${MANUAL_ARGS[@]}"); MODEL_LABEL="manual: ${MANUAL_ARGS[*]}"; CAN_FALLBACK=0
elif (( ATTEMPT >= FALLBACK_FROM_ATTEMPT )); then
  MODEL_ARGS=("${FALLBACK_ARGS[@]}"); MODEL_LABEL="$FALLBACK_MODEL"; CAN_FALLBACK=0
else
  MODEL_ARGS=("${PRIMARY_ARGS[@]}"); MODEL_LABEL="$PRIMARY_MODEL"; CAN_FALLBACK=1
fi
state_set status running assignee "codex:$MODEL_LABEL" tier "$TIER"
echo "[dispatch] $TASK_ID 第 $ATTEMPT 次，tier=$TIER effort=$EFFORT model=$MODEL_LABEL"

# 下级的权限与工具（只作用于本次调用，不改 ~/.codex/config.toml）：
# - 沙箱：只能写任务 worktree；放开网络，否则 flutter test 建不了本地 socket。
#   不用 danger-full-access：那样下级能改主检出里的 gates/ 和 tasks/，门禁就不可信了。
# - 额外可写目录：Flutter 工具运行时要写 SDK 缓存和 ~/.dart-tool，缺了 flutter test/analyze 起不来。
# - 工具：关掉插件和 rea，只留 context7 查文档，加快启动。
CODEX_ARGS=(
  -s workspace-write
  -c sandbox_workspace_write.network_access=true
  --add-dir "$(dirname "$(readlink -f "$(command -v flutter)")")/cache"
  --add-dir "$HOME/.dart-tool"
  --disable plugins
  -c mcp_servers.rea.enabled=false
)

run_codex() {
  # 超时退出码为 124，与调用失败同样处理：主力卡住不返回时由备选接手
  timeout "$WORKER_TIMEOUT" codex exec -C "$WT" "${CODEX_ARGS[@]}" "$@" \
    -o "$TASK_DIR/worker-last.md" - < "$PROMPT" >> "$TASK_DIR/worker.log" 2>&1
}

: > "$TASK_DIR/worker.log"
rm -f "$TASK_DIR/worker-last.md"
set +e
run_codex "${MODEL_ARGS[@]}"
RC=$?
# 主力调用失败（限流、服务报错等）：同一次分发内改用备选，不增加尝试次数
if (( RC != 0 && CAN_FALLBACK )); then
  echo "[dispatch] $MODEL_LABEL 调用失败（退出码 $RC），改用备选 $FALLBACK_MODEL" | tee -a "$TASK_DIR/worker.log" >&2
  MODEL_LABEL="$FALLBACK_MODEL (主力失败后接手)"
  state_set assignee "codex:$MODEL_LABEL"
  run_codex "${FALLBACK_ARGS[@]}"
  RC=$?
fi
set -e

commit_worktree "task/$TASK_ID: attempt $ATTEMPT ($MODEL_LABEL)"

if (( RC != 0 )); then
  state_set status worker_error
  echo "[dispatch] codex 退出码 $RC，详见 tasks/$TASK_ID/worker.log" >&2
  exit "$RC"
fi
state_set status awaiting_gate
echo "[dispatch] 完成。摘要: tasks/$TASK_ID/worker-last.md；下一步: gates/run.sh $TASK_ID"
