#!/usr/bin/env bash
# 分发前自检：任务的验收（accept.sh）在还没实现时应当失败。
# 如果此时就通过，说明验收什么都没检查到，或者功能已经存在——不要分发，先改验收。
# 失败时打印末尾输出，由编排者确认失败原因确实是“还没实现”，而不是验收自己写错了。
# 用法: scripts/agent/precheck.sh <task-id>    退出码 0=验收当前失败（符合预期） 1=验收当前就通过
source "$(dirname "$0")/lib.sh"
task_init "${1:-}"
require_task

if [[ ! -f "$TASK_DIR/accept.sh" ]]; then
  echo "[precheck] 任务没有 accept.sh，跳过。此时只有项目通用检查把关，确认这是有意的。"
  exit 0
fi

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
if (cd "$ROOT" && bash "$TASK_DIR/accept.sh") > "$OUT" 2>&1; then
  echo "[precheck] 不符合预期：accept.sh 在未实现时就通过了。验收没有约束力，先修改再分发。" >&2
  exit 1
fi
echo "[precheck] accept.sh 当前失败（符合预期）。请确认下面的失败原因是“尚未实现”："
tail -n 30 "$OUT"
