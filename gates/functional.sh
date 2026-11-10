#!/usr/bin/env bash
# 功能门禁：在任务 worktree 中运行静态分析、测试和任务自带的 accept.sh。
# 用法: gates/functional.sh <task-id>    退出码 0=通过
source "$(dirname "$0")/../scripts/agent/lib.sh"
task_init "${1:-}"
require_task

BASE="$(state_get base)"
cd "$WT"

echo "== flutter analyze (lib test) =="
# info 级问题不阻断（仓库基线里已有）；error/warning 阻断
flutter analyze --no-fatal-infos lib test

echo "== flutter test =="
flutter test

# 只有改到 worker/ 才跑信令服务的检查
if git -C "$ROOT" diff --name-only "$BASE" "$BRANCH" | grep -q '^worker/'; then
  echo "== worker: typecheck + test =="
  ( cd worker
    [[ -d node_modules ]] || npm ci
    npx wrangler types
    npm run typecheck
    npm test )
fi

# 任务特有验收：使用主检出里的 accept.sh（下级改不到），在 worktree 中执行
if [[ -f "$TASK_DIR/accept.sh" ]]; then
  echo "== tasks/$TASK_ID/accept.sh =="
  bash "$TASK_DIR/accept.sh"
fi

echo "functional ok"
