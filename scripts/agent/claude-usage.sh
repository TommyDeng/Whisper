#!/usr/bin/env bash
# 统计编排者（Claude Code）在一段时间内的 token 消耗，用来比较“走流水线”和“直接做”的成本。
# 数据来自 Claude Code 的会话记录（~/.claude/projects/<项目>/*.jsonl），只读。
#
# 用法: scripts/agent/claude-usage.sh <开始时间> [结束时间] [标签]
#   时间用 `date -Is` 的格式，例如 2026-11-11T10:24:40+08:00；结束时间省略表示到现在。
#   给了标签时，结果同时追加到 tasks/usage.tsv，方便以后对比。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SINCE="${1:?用法: claude-usage.sh <开始时间> [结束时间] [标签]}"
UNTIL="${2:-$(date -Is)}"
LABEL="${3:-}"
DIR="${CLAUDE_PROJECT_DIR:-$HOME/.claude/projects/$(echo "$ROOT" | sed 's/[^A-Za-z0-9]/-/g')}"
[[ -d "$DIR" ]] || { echo "找不到会话记录目录: $DIR" >&2; exit 2; }

python3 - "$DIR" "$SINCE" "$UNTIL" "$LABEL" "$ROOT/tasks/usage.tsv" <<'EOF'
import glob, json, os, sys
from datetime import datetime

directory, since, until, label, out = sys.argv[1:6]
parse = lambda s: datetime.fromisoformat(s.replace('Z', '+00:00'))
start, end = parse(since), parse(until)

# 同一条回复会在记录里出现多次（流式更新），按消息 ID 去重，保留最后一次。
usage = {}
for path in glob.glob(os.path.join(directory, '*.jsonl')):
    with open(path, encoding='utf-8') as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            message = record.get('message')
            if not isinstance(message, dict) or not message.get('usage') or not record.get('timestamp'):
                continue
            if not start <= parse(record['timestamp']) <= end:
                continue
            usage[message.get('id') or record.get('uuid')] = message['usage']

fields = ['input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'output_tokens']
total = {f: sum(int(u.get(f) or 0) for u in usage.values()) for f in fields}
print(f"时间段: {since} → {until}")
print(f"回复数: {len(usage)}")
print(f"输入(未缓存): {total['input_tokens']:,}")
print(f"写入缓存:     {total['cache_creation_input_tokens']:,}")
print(f"读取缓存:     {total['cache_read_input_tokens']:,}")
print(f"输出:         {total['output_tokens']:,}")

if label:
    new = not os.path.exists(out)
    with open(out, 'a', encoding='utf-8') as handle:
        if new:
            handle.write('label\tsince\tuntil\tturns\t' + '\t'.join(fields) + '\n')
        handle.write('\t'.join([label, since, until, str(len(usage))] + [str(total[f]) for f in fields]) + '\n')
EOF
