#!/bin/bash
# set_dirty_bit.sh — PostToolUse Hook 脚本
#
# 当检测到 Edit 或 Write 工具被调用时，设置 dirty bit。
# dirty bit 记录被修改的文件路径。
#
# 使用方式（PostToolUse hook 配置）：
#   "PostToolUse": { "command": "bash scripts/set_dirty_bit.sh ${tool},${target}" }

set -euo pipefail

DIRTY_BIT=".manus/.dirty"
MANUS_DIR=".manus"

# 确保目录存在
mkdir -p "$MANUS_DIR"

# 从参数获取工具名和目标文件
TOOL="${1:-}"
TARGET="${2:-}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [PostToolUse] $1" >> "$MANUS_DIR/logs/hook.log"
}

# 解析参数（格式：toolName,targetPath）
if [ -n "$1" ]; then
  IFS=',' read -r TOOL_NAME TARGET_PATH <<< "$1"
else
  log "未提供参数"
  exit 0
fi

log "Tool: $TOOL_NAME, Target: $TARGET_PATH"

# 只处理 Edit 和 Write 工具
if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
  log "检测到文件修改: $TARGET_PATH"

  # 将修改的文件追加到 dirty bit
  echo "$TARGET_PATH" >> "$DIRTY_BIT"

  # 去重
  sort -u "$DIRTY_BIT" -o "$DIRTY_BIT"

  log "Dirty bit 已更新: $(cat "$DIRTY_BIT" | tr '\n' ' ')"
fi

exit 0
