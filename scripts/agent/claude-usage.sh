#!/usr/bin/env bash
# 统计编排者（Claude Code）的 token 消耗，用来比较“走流水线”和“直接做”的成本。
# 数据来自 Claude Code 的会话记录（~/.claude/projects/<项目>/*.jsonl），只读。
#
# 用法:
#   scripts/agent/claude-usage.sh --task <task-id>
#       按任务统计：从建任务（created_at）到合并（merged_at，没合并则到现在），
#       覆盖写说明、分发、过门禁、审查的全过程。结果追加到 tasks/usage.tsv。
#   scripts/agent/claude-usage.sh <开始时间> [结束时间] [标签]
#       按时间段统计，时间用 `date -Is` 的格式；给了标签时追加到 tasks/usage.tsv。
#       用来给“直接做”的工作记一笔，开始前先 `date -Is` 记下时间。
#
# 局限：统计的是时间段内本项目所有会话的消耗。同一时间段里如果还做了别的事，也会算进来；
# 要做对比，请保证这段时间只做这一件事，最好各用一个新会话。
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

if [[ "${1:-}" == "--task" ]]; then
  ID="${2:?用法: claude-usage.sh --task <task-id>}"
  STATE="$ROOT/tasks/$ID/state.json"
  [[ -f "$STATE" ]] || { echo "任务不存在: $ID" >&2; exit 2; }
  SINCE="$(jq -r '.created_at // empty' "$STATE")"
  UNTIL="$(jq -r '.merged_at // empty' "$STATE")"
  [[ -n "$SINCE" ]] || { echo "tasks/$ID/state.json 没有 created_at（旧版本建的任务），请改用时间段方式" >&2; exit 2; }
  UNTIL="${UNTIL:-$(date -Is)}"
  LABEL="pipeline:$ID"
else
  SINCE="${1:?用法: claude-usage.sh --task <task-id> | <开始时间> [结束时间] [标签]}"
  UNTIL="${2:-$(date -Is)}"
  LABEL="${3:-}"
fi

DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/projects/$(echo "$ROOT" | sed 's/[^A-Za-z0-9]/-/g')}"
[[ -d "$DIR" ]] || { echo "找不到会话记录目录: $DIR" >&2; exit 2; }

python3 - "$DIR" "$SINCE" "$UNTIL" "$LABEL" "$ROOT/tasks/usage.tsv" <<'PY'
import glob, json, os, sys
from datetime import datetime

directory, since, until, label, out = sys.argv[1:6]
parse = lambda s: datetime.fromisoformat(s.replace('Z', '+00:00'))
start, end = parse(since), parse(until)

# 同一条回复会在记录里出现多次（流式更新），按消息 ID 去重，保留最后一次。
# 子代理的会话记录在子目录里，一并统计。
usage = {}
for path in glob.glob(os.path.join(directory, '**', '*.jsonl'), recursive=True):
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
PY
