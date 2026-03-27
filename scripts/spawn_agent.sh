#!/bin/bash
# cc_dispatch.sh: 在远程服务器上以 tmux 守护方式异步启动 Claude Code 任务
#
# 用法:
#   bash cc_dispatch.sh <ssh_target> <task_id> <prompt> [work_dir] [allowed_tools]
#
# 参数:
#   ssh_target    - SSH 连接目标, 如 user@host 或 host (依赖 ~/.ssh/config)
#   task_id       - 唯一任务 ID, 用于 tmux 会话名和日志文件名, 如 task_20260326_001
#   prompt        - 传递给 Claude Code 的任务 Prompt (建议用单引号包裹)
#   work_dir      - (可选) 远程工作目录, 默认 ~/project
#   allowed_tools - (可选) 逗号分隔的工具白名单, 如 "Read,Edit,Bash"
#
# 输出:
#   成功时打印 JSON: {"status":"dispatched","task_id":"...","session":"...","log":"..."}
#   失败时打印 JSON: {"status":"error","message":"..."}

set -euo pipefail

SSH_TARGET="${1:?必须提供 ssh_target}"
TASK_ID="${2:?必须提供 task_id}"
PROMPT="${3:?必须提供 prompt}"
WORK_DIR="${4:-~/project}"
ALLOWED_TOOLS="${5:-}"

SESSION_NAME="cc_${TASK_ID}"
MANUS_DIR="${WORK_DIR}/.manus"
LOG_FILE="${MANUS_DIR}/logs/${TASK_ID}.log"
EXIT_FILE="${MANUS_DIR}/logs/${TASK_ID}.exit"
LOCK_FILE="${MANUS_DIR}/orchestration.lock"

# 构建 allowed_tools 参数
TOOLS_ARG=""
if [ -n "$ALLOWED_TOOLS" ]; then
  TOOLS_ARG="--allowedTools \"${ALLOWED_TOOLS}\""
fi

# 在远程执行的完整命令
REMOTE_CMD=$(cat <<REMOTE
set -e
mkdir -p "${MANUS_DIR}/logs"

# 检查锁文件，防止并发冲突
if [ -f "${LOCK_FILE}" ]; then
  LOCKED_PID=\$(jq -r '.pid' "${LOCK_FILE}" 2>/dev/null || echo "")
  LOCKED_TASK=\$(jq -r '.task_id' "${LOCK_FILE}" 2>/dev/null || echo "")
  if [ -n "\$LOCKED_PID" ] && kill -0 "\$LOCKED_PID" 2>/dev/null; then
    echo '{"status":"locked","task_id":"'"\$LOCKED_TASK"'","pid":"'"\$LOCKED_PID"'"}'
    exit 1
  fi
fi

# 检查同名 tmux 会话是否已存在（幂等性保护）
if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
  echo '{"status":"already_running","task_id":"${TASK_ID}","session":"${SESSION_NAME}"}'
  exit 0
fi

# 启动 tmux 守护会话，运行 Claude Code
tmux new-session -d -s "${SESSION_NAME}" -c "${WORK_DIR}" \
  "timeout 7200s claude -p ${TOOLS_ARG} --output-format json '${PROMPT}' > '${LOG_FILE}' 2>&1; echo \$? > '${EXIT_FILE}'"

# 写入锁文件
TMUX_PID=\$(tmux list-panes -t "${SESSION_NAME}" -F '#{pane_pid}' 2>/dev/null | head -1)
echo "{\"task_id\":\"${TASK_ID}\",\"session\":\"${SESSION_NAME}\",\"pid\":\"\$TMUX_PID\",\"started_at\":\"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"work_dir\":\"${WORK_DIR}\"}" > "${LOCK_FILE}"

echo '{"status":"dispatched","task_id":"${TASK_ID}","session":"${SESSION_NAME}","log":"${LOG_FILE}"}'
REMOTE
)

RESULT=$(ssh "$SSH_TARGET" "$REMOTE_CMD" 2>&1)
echo "$RESULT"
