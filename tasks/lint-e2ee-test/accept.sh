#!/usr/bin/env bash
# 在任务 worktree 根目录执行
set -euo pipefail
F=test/e2ee_security_test.dart

flutter analyze --fatal-infos "$F"

if grep -nE '//\s*ignore(_for_file)?:' "$F"; then
  echo "ACCEPT FAIL: 不允许用 ignore 注释压告警" >&2; exit 1
fi

# 用例数量不得减少（防止通过删测试过关）
BASE_COUNT=$(git show "$(git merge-base HEAD main 2>/dev/null || git rev-parse HEAD~1)":"$F" | grep -cE "^\s*test\(")
NOW_COUNT=$(grep -cE "^\s*test\(" "$F")
if (( NOW_COUNT < BASE_COUNT )); then
  echo "ACCEPT FAIL: 用例数从 $BASE_COUNT 减少到 $NOW_COUNT" >&2; exit 1
fi
echo "accept ok: $NOW_COUNT 个用例，analyze 无告警"
