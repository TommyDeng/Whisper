#!/usr/bin/env bash
# 让 Codex 审查任务分支相对 base 的 diff，结果写入 tasks/<id>/review.md。
# 仅用于"实现者不是 Codex"的任务；Codex 实现的任务由 Claude 审查，保证审查者与实现者不同模型。
# 用法: scripts/agent/review.sh <task-id> [-m <model>]
source "$(dirname "$0")/lib.sh"
task_init "${1:-}"; shift || true
require_task

MODEL_ARGS=()
while getopts "m:" opt; do
  case "$opt" in m) MODEL_ARGS=(-m "$OPTARG");; *) exit 2;; esac
done

BASE="$(state_get base)"
cd "$WT"
codex exec review --base "$BASE" "${MODEL_ARGS[@]}" \
  "对照下面的任务说明审查这份改动。重点：与说明不符之处、说明里没有要求的行为、过度实现、安全问题、被削弱或绕过的测试。逐条给出 文件:行号 + 问题 + 严重程度。

$(cat "$TASK_DIR/spec.md")" > "$TASK_DIR/review.md" 2> "$TASK_DIR/review.log"
echo "审查意见: tasks/$TASK_ID/review.md"
