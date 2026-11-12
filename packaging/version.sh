#!/bin/bash
# 打印发行版本号（不含 build 号）。优先用环境变量 VERSION，否则读 pubspec.yaml。
set -euo pipefail
if [ -n "${VERSION:-}" ]; then
  echo "$VERSION"
  exit 0
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# pubspec.yaml: version: 1.0.0+1
line="$(grep -E '^version:' "$ROOT/pubspec.yaml" | head -n1)"
ver="${line#version:}"
ver="${ver%%+*}"
ver="$(echo "$ver" | tr -d '[:space:]')"
if [ -z "$ver" ]; then
  echo "无法从 pubspec.yaml 读出版本号" >&2
  exit 1
fi
echo "$ver"
