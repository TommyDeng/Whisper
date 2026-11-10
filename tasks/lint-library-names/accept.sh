#!/usr/bin/env bash
set -euo pipefail
OUT="$(flutter analyze --no-fatal-infos lib 2>&1 || true)"
if grep -q 'unnecessary_library_name' <<<"$OUT"; then
  grep 'unnecessary_library_name' <<<"$OUT" >&2; echo "ACCEPT FAIL: 仍有 unnecessary_library_name" >&2; exit 1
fi
# 不允许靠删掉 library 指令上方的文档注释之外的内容过关：每个文件仍须有 library; 指令
for f in $(grep -vE '^\s*(#|$)' "$(dirname "$0")/allowed_paths"); do
  grep -qE '^library;$' "$f" || { echo "ACCEPT FAIL: $f 缺少 library; 指令" >&2; exit 1; }
  ! grep -nE '//\s*ignore(_for_file)?:' "$f" || { echo "ACCEPT FAIL: $f 使用了 ignore 注释" >&2; exit 1; }
done
echo "accept ok"
