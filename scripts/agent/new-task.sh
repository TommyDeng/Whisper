#!/usr/bin/env bash
# 新建任务骨架：tasks/<id>/{spec.md,allowed_paths,state.json}
source "$(dirname "$0")/lib.sh"
task_init "${1:-}"

[[ -e "$TASK_DIR" ]] && { echo "任务已存在: $TASK_DIR" >&2; exit 2; }
mkdir -p "$TASK_DIR"

cat > "$TASK_DIR/spec.md" <<'EOF'
# 任务：<一句话标题>

## 目标
<要达成什么，为什么>

## 具体要求
- <可检查的要求>

## 验收
- `flutter analyze --no-fatal-infos lib test` 无 error/warning
- `flutter test` 全部通过
- <本任务特有的验收命令，同时写进 accept.sh>

## 不要做
- 不要修改 allowed_paths 以外的文件
EOF

cat > "$TASK_DIR/allowed_paths" <<'EOF'
# 每行一个允许修改的路径或 glob（相对仓库根目录），# 开头为注释。
# 例：
# lib/transfer/**
# test/transfer_test.dart
EOF

# 任务类型：logic（默认）或 mechanical，决定下级的推理强度，见 scripts/agent/models.conf
echo "logic" > "$TASK_DIR/tier"

jq -n --arg id "$TASK_ID" --arg now "$(date -Is)" \
  '{id:$id,status:"pending",attempts:0,assignee:"",branch:"",base:"",updated_at:$now}' > "$STATE"

echo "已创建 $TASK_DIR"
echo "下一步：填写 spec.md、allowed_paths 和 tier（可选 accept.sh），提交后运行 scripts/agent/dispatch.sh $TASK_ID"
