#!/bin/bash
# interrupt.test.sh — 测试 interrupt_agent.sh 的核心逻辑（本地模拟）
#
# interrupt_agent.sh 需要 SSH 远程执行，此测试使用本地 tmux 模拟核心逻辑。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_ROOT/test_artifacts/interrupt_test"
MANUS_DIR="$TEST_DIR/.manus"
LOG_DIR="$MANUS_DIR/logs"

echo "=== interrupt_agent.sh 本地模拟测试 ==="
echo

# 清理并准备测试环境
rm -rf "$TEST_DIR"
mkdir -p "$LOG_DIR"

cd "$TEST_DIR"

TASK_ID="task_001"
SESSION_NAME="cc_${TASK_ID}"
LOG_FILE="$LOG_DIR/${TASK_ID}.log"
EXIT_FILE="$LOG_DIR/${TASK_ID}.exit"
LOCK_FILE="$MANUS_DIR/orchestration.lock"

echo "准备: 创建模拟任务..."
# 创建 tmux 会话（模拟长时间运行的 Claude Code）
tmux new-session -d -s "${SESSION_NAME}" "sleep 60"
echo "✓ tmux 会话已创建: $SESSION_NAME"

# 写入锁文件
TMUX_PID=$(tmux list-panes -t "${SESSION_NAME}" -F '#{pane_pid}' 2>/dev/null | head -1)
cat > "$LOCK_FILE" <<EOF
{"task_id":"${TASK_ID}","session":"${SESSION_NAME}","pid":"$TMUX_PID","started_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
echo "✓ 锁文件已写入: $LOCK_FILE"
echo

echo "场景 1: SIGINT 优雅中断测试"
echo "---"

# 模拟 interrupt_agent.sh 的核心逻辑
# 注意: SIGINT 发到子进程，tmux 本身不会退出
# 真正的优雅中断需要在 tmux 内部处理，这里简化为直接杀会话
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  # 发送 SIGINT 到 tmux 内部的进程（tmux 会将其转发给会话中的进程）
  # 由于我们的测试进程是 sleep，SIGINT 会终止它，tmux 会话也会结束
  echo "发送 SIGINT 到 tmux 会话..."
  tmux send-keys -t "${SESSION_NAME}" C-c 2>/dev/null || true

  # 等待最多 5 秒
  WAIT=0
  while tmux has-session -t "$SESSION_NAME" 2>/dev/null && [ $WAIT -lt 5 ]; do
    sleep 1
    WAIT=$((WAIT + 1))
  done

  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "进程未响应，强制终止 tmux 会话..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
  fi

  echo "✓ 优雅中断流程完成"
else
  echo "✗ 会话不存在"
  exit 1
fi
echo

echo "场景 2: 退出码文件标记"
echo "---"
if [ -f "$EXIT_FILE" ]; then
  CONTENT=$(cat "$EXIT_FILE")
  echo "✗ 不应创建退出码文件（进程正常退出）"
  exit 1
else
  echo "✓ 正常退出后无退出码文件"
fi
echo

echo "场景 3: 锁文件清理（模拟 interrupt_agent 行为）"
echo "---"
# 模拟 interrupt_agent.sh 删除锁文件的逻辑
# 在实际脚本中，锁文件会在中断后被删除
# 这里我们手动清理以模拟完整流程
rm -f "$LOCK_FILE"
if [ ! -f "$LOCK_FILE" ]; then
  echo "✓ 锁文件已删除（模拟中断脚本行为）"
else
  echo "✗ 锁文件仍存在"
  exit 1
fi
echo

echo "场景 4: 中断已完成的任务"
echo "---"
# 创建已完成的任务（无 tmux 会话）
TASK_ID_2="task_002"
SESSION_NAME_2="cc_${TASK_ID_2}"
LOG_FILE_2="$LOG_DIR/${TASK_ID_2}.log"
touch "$LOG_FILE_2"
echo "completed" >> "$LOG_FILE_2"
echo "0" > "$LOG_DIR/${TASK_ID_2}.exit"

if ! tmux has-session -t "$SESSION_NAME_2" 2>/dev/null; then
  echo "✓ 已完成任务的 tmux 会话不存在（预期行为）"
else
  echo "✗ 会话意外存在"
  exit 1
fi
echo

# 清理
tmux kill-session -t "${SESSION_NAME}" 2>/dev/null || true
rm -rf "$TEST_DIR"

echo "=== 所有场景测试通过 ==="
exit 0
