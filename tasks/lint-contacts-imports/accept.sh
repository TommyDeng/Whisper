#!/usr/bin/env bash
# 在任务 worktree 根目录执行
set -euo pipefail
F=lib/ui/contacts_list.dart
# 只检查本任务要消除的告警；该文件另有一条与任务无关的 dangling_library_doc_comments，不在范围内
OUT="$(flutter analyze --no-fatal-infos "$F" 2>&1 || true)"
if grep -q 'unnecessary_import' <<<"$OUT"; then
  grep 'unnecessary_import' <<<"$OUT" >&2; echo "ACCEPT FAIL: 仍有 unnecessary_import" >&2; exit 1
fi
! grep -nE '//\s*ignore(_for_file)?:' "$F" || { echo "ACCEPT FAIL: 不允许用 ignore 注释" >&2; exit 1; }
echo "accept ok"
