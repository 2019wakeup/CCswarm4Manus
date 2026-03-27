#!/bin/bash
# scripts/validate_settings.sh — Claude Code settings.json Schema 校验脚本
#
# 用法:
#   bash scripts/validate_settings.sh [path/to/settings.json]
#
# 功能:
#   1. 验证 JSON 语法合法性
#   2. 检查 hooks.PostToolUse 必须为数组（新版格式）
#   3. 检查 hooks.Stop 必须为数组（新版格式）
#   4. 检查 matcher 字段必须为字符串（非对象）
#
# 退出码:
#   0 — 全部校验通过
#   1 — 校验失败（含具体错误信息）
#
# 兼容版本: Claude Code >= v2.1.71

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SETTINGS_FILE="${1:-.claude/settings.json}"

echo "Validating: ${SETTINGS_FILE}"

# 1. 检查文件是否存在
if [ ! -f "${SETTINGS_FILE}" ]; then
  echo -e "${RED}[ERROR]${NC} File not found: ${SETTINGS_FILE}"
  exit 1
fi

# 2. 验证 JSON 语法
if ! python3 -m json.tool "${SETTINGS_FILE}" > /dev/null 2>&1; then
  echo -e "${RED}[ERROR]${NC} Invalid JSON syntax in ${SETTINGS_FILE}"
  python3 -m json.tool "${SETTINGS_FILE}" 2>&1 | head -5
  exit 1
fi

# 3. 检查 hooks.PostToolUse 必须为数组
python3 - "${SETTINGS_FILE}" << 'PYEOF'
import json, sys

settings_file = sys.argv[1]
with open(settings_file) as f:
    d = json.load(f)

hooks = d.get("hooks", {})
errors = []

# PostToolUse 必须是数组
post_tool_use = hooks.get("PostToolUse")
if post_tool_use is not None:
    if not isinstance(post_tool_use, list):
        errors.append(
            f"hooks.PostToolUse must be an array (got {type(post_tool_use).__name__}). "
            "New format: [{\"matcher\": \"Edit|Write\", \"hooks\": [{\"type\": \"command\", \"command\": \"...\"}]}]"
        )
    else:
        for i, item in enumerate(post_tool_use):
            matcher = item.get("matcher")
            if matcher is not None and not isinstance(matcher, str):
                errors.append(
                    f"hooks.PostToolUse[{i}].matcher must be a string regex (got {type(matcher).__name__}). "
                    "Example: \"Edit|Write\""
                )

# Stop 必须是数组
stop = hooks.get("Stop")
if stop is not None:
    if not isinstance(stop, list):
        errors.append(
            f"hooks.Stop must be an array (got {type(stop).__name__}). "
            "New format: [{\"hooks\": [{\"type\": \"command\", \"command\": \"...\"}]}]"
        )

if errors:
    for err in errors:
        print(f"[SCHEMA ERROR] {err}", file=sys.stderr)
    sys.exit(1)

print("[OK] settings.json schema valid (Claude Code >= v2.1.71 compatible)")
PYEOF

EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
  echo -e "${RED}[FAIL]${NC} Schema validation failed for ${SETTINGS_FILE}"
  exit 1
fi

echo -e "${GREEN}[PASS]${NC} ${SETTINGS_FILE} is valid"
