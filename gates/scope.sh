#!/usr/bin/env bash
# 范围门禁：任务分支相对 base 的改动必须全部落在 allowed_paths 内，且不得触碰受保护路径。
# 用法: gates/scope.sh <task-id>    退出码 0=通过 1=越界
source "$(dirname "$0")/../scripts/agent/lib.sh"
task_init "${1:-}"
require_task

# 无论 allowed_paths 怎么写都不允许下级修改的路径
PROTECTED=('gates/**' 'scripts/agent/**' 'tasks/**' '.github/**' 'CLAUDE.md' 'AGENTS.md')

BASE="$(state_get base)"
[[ -n "$BASE" ]] || { echo "state.json 缺少 base，任务尚未分发" >&2; exit 2; }

mapfile -t ALLOWED < <(grep -vE '^\s*(#|$)' "$TASK_DIR/allowed_paths" | sed 's/[[:space:]]*$//')
mapfile -t CHANGED < <(git -C "$ROOT" diff --name-only "$BASE" "$BRANCH")

# glob 匹配：** 与 * 都可跨目录（bash [[ == ]] 中 * 本身就匹配 /）
matches() { local f="$1" p; shift; for p in "$@"; do [[ "$f" == $p ]] && return 0; done; return 1; }

FAIL=0
for f in "${CHANGED[@]}"; do
  if matches "$f" "${PROTECTED[@]}"; then
    echo "SCOPE FAIL: 修改了受保护路径: $f" >&2; FAIL=1
  elif ! matches "$f" "${ALLOWED[@]}"; then
    echo "SCOPE FAIL: 超出 allowed_paths: $f" >&2; FAIL=1
  fi
done

if (( ${#CHANGED[@]} == 0 )); then
  echo "SCOPE FAIL: 任务分支相对 base 没有任何改动" >&2; FAIL=1
fi

(( FAIL == 0 )) && echo "scope ok: ${#CHANGED[@]} 个文件均在允许范围内"
exit "$FAIL"
