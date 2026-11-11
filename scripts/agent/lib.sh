#!/usr/bin/env bash
# 编排脚本共用函数。由其它脚本 source，不单独执行。
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

# 无论 allowed_paths 怎么写都不允许下级修改的路径
PROTECTED=('gates/**' 'scripts/agent/**' 'tasks/**' '.github/**' 'agent.conf' 'CLAUDE.md' 'AGENTS.md')

# 读取项目配置 agent.conf（始终用主检出里的那份，下级改不到）。各项的含义见该文件。
load_conf() {
  SETUP_CMD=""
  CHECKS=()
  CONDITIONAL_CHECKS=()
  SANDBOX_WRITABLE_DIRS=()
  CODEX_EXTRA_ARGS=()
  DISPATCH_CLEAN_PATHS=()
  WORKER_HINTS=""
  [[ -f "$ROOT/agent.conf" ]] || { echo "缺少 $ROOT/agent.conf（项目配置）" >&2; exit 2; }
  # shellcheck disable=SC1091
  source "$ROOT/agent.conf"
}

task_init() {
  TASK_ID="${1:?用法: $0 <task-id>}"
  [[ "$TASK_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "task-id 只能包含小写字母、数字和连字符" >&2; exit 2; }
  TASK_DIR="$ROOT/tasks/$TASK_ID"
  STATE="$TASK_DIR/state.json"
  WT="$ROOT/.worktrees/$TASK_ID"
  BRANCH="task/$TASK_ID"
}

require_task() {
  [[ -f "$TASK_DIR/spec.md" && -f "$STATE" ]] || { echo "任务不存在: $TASK_ID（先运行 scripts/agent/new-task.sh）" >&2; exit 2; }
}

state_get() { jq -r --arg k "$1" '.[$k] // empty' "$STATE"; }

# state_set key value [key value ...]，值一律按字符串写入；attempts 用 state_bump。
state_set() {
  local tmp; tmp="$(mktemp)"
  local args=() filter='.updated_at = $now'
  while (($#)); do
    args+=(--arg "$1" "$2"); filter+=" | .$1 = \$$1"; shift 2
  done
  jq --arg now "$(date -Is)" "${args[@]}" "$filter" "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

state_bump() {
  local tmp; tmp="$(mktemp)"
  jq --arg now "$(date -Is)" '.attempts += 1 | .updated_at = $now' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

# 只在还没记过时写入时间点（例如 dispatched_at 只记第一次分发）。
state_mark_once() {
  [[ -n "$(state_get "$1")" ]] || state_set "$1" "$(date -Is)"
}

# 把 worktree 里未提交的改动提交到任务分支，让门禁只需要看提交。
commit_worktree() {
  local msg="$1"
  git -C "$WT" add -A
  if ! git -C "$WT" diff --cached --quiet; then
    git -C "$WT" commit -q -m "$msg"
  fi
}

# 流水线自己的运行期状态（不入库，各 worktree 共用），例如主力模型的冷却标记。
runtime_dir() {
  local dir
  dir="$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)/agent-pipeline"
  mkdir -p "$dir"
  echo "$dir"
}
