#!/bin/bash
# setup.sh — Claude Code 节点化编排平台安装脚本
#
# 用法:
#   bash setup.sh [--ssh-target <user@host>] [--work-dir <path>]
#
# 功能:
#   1. 检查并安装必要依赖 (Node.js, tmux, jq, sshpass, flock)
#   2. 安装 Claude Code CLI (如未安装)
#   3. 配置本地 SSH 连接复用
#   4. 在远程服务器初始化沙箱环境 (如指定 --ssh-target)
#   5. 验证安装

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 默认参数
SSH_TARGET=""
WORK_DIR="~/project"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 解析参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --ssh-target)
      SSH_TARGET="$2"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    *)
      log_error "未知参数: $1"
      exit 1
      ;;
  esac
done

echo "=== Claude Code 节点化编排平台安装 ==="
echo

# 1. 检查并安装必要依赖
log_info "检查系统依赖..."

install_package() {
  if command -v brew >/dev/null 2>&1; then
    brew install "$1" 2>/dev/null || true
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y "$1" 2>/dev/null || true
  fi
}

# 检查 Node.js
if ! command -v node >/dev/null 2>&1; then
  log_warn "Node.js 未安装"
  install_package "node"
fi

# 检查必要工具
for tool in tmux jq sshpass flock; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_info "安装 $tool..."
    install_package "$tool"
  else
    log_info "$tool 已安装: $(which "$tool")"
  fi
done

# macOS 特别处理 flock
if [[ "$(uname)" == "Darwin" ]] && ! command -v flock >/dev/null 2>&1; then
  log_info "macOS 安装 flock..."
  brew install flock 2>/dev/null || true
fi

echo

# 2. 检查 Claude Code CLI
log_info "检查 Claude Code CLI..."
if command -v claude >/dev/null 2>&1; then
  CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown")
  log_info "Claude Code 已安装: $CLAUDE_VERSION"
else
  log_warn "Claude Code CLI 未安装"
  log_info "安装方法: https://docs.anthropic.com/en/docs/claude-code/setup"
  echo "  macOS: brew install anthropic/formulas/claude"
  echo "  Linux: curl -sL https://claude.ai/dl/linux | bash"
fi

echo

# 3. 配置 SSH 连接复用
log_info "配置 SSH 连接复用..."
mkdir -p ~/.ssh/sockets
cat >> ~/.ssh/config <<'EOF'

# Claude Code Orchestration SSH Config
Host *
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h:%p
    ControlPersist 600
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
log_info "SSH 配置已更新: ~/.ssh/config"
echo

# 4. 初始化远程沙箱 (如指定)
if [ -n "$SSH_TARGET" ]; then
  log_info "初始化远程沙箱: $SSH_TARGET"
  echo

  # 检查本地是否有 sshpass
  if ! command -v sshpass >/dev/null 2>&1; then
    log_warn "sshpass 未安装，远程初始化可能需要手动密码输入"
  fi

  # 解压 skill 文件中的初始化脚本并执行
  if [ -f "$PROJECT_DIR/ssh-remote-interaction.skill" ]; then
    TMP_DIR=$(mktemp -d)
    unzip -o "$PROJECT_DIR/ssh-remote-interaction.skill" scripts/init_sandbox.sh -d "$TMP_DIR" 2>/dev/null || true
    if [ -f "$TMP_DIR/scripts/init_sandbox.sh" ]; then
      log_info "执行远程初始化脚本..."
      ssh "$SSH_TARGET" "bash -s" < "$TMP_DIR/scripts/init_sandbox.sh" || log_warn "远程初始化失败，请手动执行"
    fi
    rm -rf "$TMP_DIR"
  else
    log_warn "ssh-remote-interaction.skill 未找到，跳过远程初始化"
  fi

  echo
fi

# 5. 验证安装
log_info "验证安装..."
echo

MISSING=0

if ! command -v node >/dev/null 2>&1; then
  log_error "Node.js 未安装"
  MISSING=1
fi

if ! command -v tmux >/dev/null 2>&1; then
  log_error "tmux 未安装"
  MISSING=1
fi

if ! command -v jq >/dev/null 2>&1; then
  log_error "jq 未安装"
  MISSING=1
fi

if ! command -v flock >/dev/null 2>&1; then
  log_error "flock 未安装"
  MISSING=1
fi

if [ $MISSING -eq 0 ]; then
  log_info "所有依赖已安装 ✅"
else
  log_error "部分依赖缺失，请手动安装"
  exit 1
fi

echo
echo "=== 安装完成 ==="
echo
echo "下一步:"
echo "  1. 配置 SSH 免密登录到远程服务器"
echo "  2. 运行测试验证: bash test/state_manager.test.sh"
echo "  3. 开始使用: 参考 README.md"
