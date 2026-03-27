#!/bin/bash
# verify_before_exit.sh — 强制验证拦截脚本
#
# 当 Claude Code Agent 尝试退出时调用此脚本。
# 如果代码被修改过（dirty bit），强制运行 lint 和测试。
# 测试失败返回 Exit Code 2，阻断 Agent 退出。
#
# 使用方式（Stop hook 配置）：
#   "Stop": { "command": "bash scripts/verify_before_exit.sh" }

set -euo pipefail

DIRTY_BIT=".manus/.dirty"
LOG_FILE=".manus/logs/verify.log"
EXIT_CODE=0

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$LOG_FILE"
}

log "=== verify_before_exit.sh 启动 ==="

# 检查 dirty bit 是否存在
if [ ! -f "$DIRTY_BIT" ]; then
  log "Dirty bit 不存在，代码未被修改，放行退出"
  exit 0
fi

DIRTY_FILES=$(cat "$DIRTY_BIT" 2>/dev/null | tr '\n' ' ')
log "检测到代码已修改: $DIRTY_FILES"

# 检查是否有 package.json 和 lint/test 脚本
if [ -f "package.json" ]; then
  # 检查 npm scripts
  if grep -q '"lint"' package.json 2>/dev/null; then
    log "运行 npm run lint..."
    if ! npm run lint >> "$LOG_FILE" 2>&1; then
      log "Lint 失败！阻断退出"
      EXIT_CODE=2
    else
      log "Lint 通过"
    fi
  fi

  # 检查 npm scripts
  if grep -q '"test"' package.json 2>/dev/null; then
    log "运行 npm test..."
    if ! npm test >> "$LOG_FILE" 2>&1; then
      log "测试失败！阻断退出"
      EXIT_CODE=2
    else
      log "测试通过"
    fi
  fi
else
  log "未找到 package.json，跳过 npm 验证"
fi

# 检查是否有 .eslintrc 或 eslint 配置
if [ -f ".eslintrc.js" ] || [ -f ".eslintrc.json" ] || [ -f ".eslintrc" ]; then
  log "运行 ESLint..."
  if command -v npx >/dev/null 2>&1; then
    if ! npx eslint --ext .js,.ts,.jsx,.tsx . >> "$LOG_FILE" 2>&1; then
      log "ESLint 失败！阻断退出"
      EXIT_CODE=2
    else
      log "ESLint 通过"
    fi
  fi
fi

# 检查是否有 jest.config.js
if [ -f "jest.config.js" ] || grep -q '"jest"' package.json 2>/dev/null; then
  log "运行 Jest..."
  if command -v npx >/dev/null 2>&1; then
    if ! npx jest >> "$LOG_FILE" 2>&1; then
      log "Jest 失败！阻断退出"
      EXIT_CODE=2
    else
      log "Jest 通过"
    fi
  fi
fi

if [ $EXIT_CODE -eq 0 ]; then
  log "所有验证通过，清除 dirty bit"
  rm -f "$DIRTY_BIT"
else
  log "验证失败，返回 Exit Code $EXIT_CODE"
fi

log "=== verify_before_exit.sh 结束 ==="
exit $EXIT_CODE
