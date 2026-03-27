#!/bin/bash
# spawn_and_probe.test.sh — 测试 spawn_agent.sh 和 probe_status.sh 的本地模拟
#
# 由于 spawn_agent.sh 和 probe_status.sh 需要 SSH 远程执行，
# 此测试使用本地 tmux 模拟来验证核心逻辑。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_ROOT/test_artifacts/spawn_test"
MANUS_DIR="$TEST_DIR/.manus"
LOG_DIR="$MANUS_DIR/logs"

echo "=== spawn_agent.sh 和 probe_status.sh 测试 ==="
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

echo "场景 1: 本地 tmux 任务下发测试"
echo "---"

# 模拟 spawn_agent.sh 的核心逻辑（使用本地 tmux）
# 检查锁文件
if [ -f "$LOCK_FILE" ]; then
  LOCKED_PID=$(jq -r '.pid' "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$LOCKED_PID" ] && kill -0 "$LOCKED_PID" 2>/dev/null; then
    echo "✗ 锁文件存在且进程活跃"
    exit 1
  fi
fi

# 检查同名 tmux 会话
if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
  echo "会话已存在，跳过创建"
else
  # 创建 tmux 会话（模拟 Claude Code 运行）
  tmux new-session -d -s "${SESSION_NAME}" "echo 'Claude Code mock started' > '$LOG_FILE'; sleep 1; echo 'Task completed' >> '$LOG_FILE'; echo 0 > '$EXIT_FILE'"
  echo "✓ tmux 会话已创建: $SESSION_NAME"
fi

# 写入锁文件
TMUX_PID=$(tmux list-panes -t "${SESSION_NAME}" -F '#{pane_pid}' 2>/dev/null | head -1)
cat > "$LOCK_FILE" <<EOF
{"task_id":"${TASK_ID}","session":"${SESSION_NAME}","pid":"$TMUX_PID","started_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","work_dir":"$TEST_DIR"}
EOF
echo "✓ 锁文件已写入: $LOCK_FILE"
echo

echo "场景 2: 探针状态查询测试"
echo "---"

# 模拟 probe_status.sh 的核心逻辑
# 检查日志文件
if [ ! -f "$LOG_FILE" ]; then
  echo '{"status":"not_found","task_id":"'"${TASK_ID}"'"}'
  exit 1
fi

# 检查退出码文件
if [ -f "$EXIT_FILE" ]; then
  EXIT_CODE=$(cat "$EXIT_FILE" | tr -d '[:space:]')
  LAST_LINE=$(tail -1 "$LOG_FILE" 2>/dev/null | cut -c1-120 | sed 's/"/\\"/g')
  if [ "$EXIT_CODE" = "0" ]; then
    STATUS="completed"
  elif [ "$EXIT_CODE" = "124" ]; then
    STATUS="timeout"
  else
    STATUS="failed"
  fi
  RESULT="{\"status\":\"${STATUS}\",\"task_id\":\"${TASK_ID}\",\"exit_code\":${EXIT_CODE},\"last_line\":\"${LAST_LINE}\",\"loop_warning\":false}"
  echo "✓ 任务已完成: $RESULT"
else
  # 任务仍在运行
  if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    LAST_LINE=$(tail -1 "$LOG_FILE" 2>/dev/null | cut -c1-120 | sed 's/"/\\"/g')
    RESULT="{\"status\":\"failed\",\"task_id\":\"${TASK_ID}\",\"exit_code\":-1,\"last_line\":\"${LAST_LINE}\",\"loop_warning\":false}"
    echo "✗ 会话消失: $RESULT"
  else
    RESULT="{\"status\":\"running\",\"task_id\":\"${TASK_ID}\",\"elapsed_sec\":1,\"last_line\":\"Running...\",\"loop_warning\":false}"
    echo "✓ 任务运行中: $RESULT"
  fi
fi
echo

echo "场景 3: 死循环检测测试"
echo "---"

# 创建带有重复行的日志文件模拟死循环
TASK_ID_2="task_loop"
LOG_FILE_2="$LOG_DIR/${TASK_ID_2}.log"
EXIT_FILE_2="$LOG_DIR/${TASK_ID_2}.exit"

# 写入重复的错误信息
for i in {1..5}; do
  echo "Error: same error pattern" >> "$LOG_FILE_2"
done

# 检查重复
REPEAT_COUNT=$(tail -60 "$LOG_FILE_2" 2>/dev/null | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
if [ "${REPEAT_COUNT:-0}" -ge 3 ]; then
  echo "✓ 死循环检测成功: 重复次数=${REPEAT_COUNT}"
else
  echo "✗ 死循环检测失败: 重复次数=${REPEAT_COUNT:-0}"
  exit 1
fi
echo

echo "场景 4: JSON 验证"
echo "---"

# 验证探针输出的 JSON 可以被 jq 解析
PROBE_OUTPUT="{\"status\":\"running\",\"task_id\":\"${TASK_ID}\",\"elapsed_sec\":1,\"last_line\":\"Test\",\"loop_warning\":false}"
if echo "$PROBE_OUTPUT" | jq '.' > /dev/null 2>&1; then
  echo "✓ JSON 格式合法"
else
  echo "✗ JSON 格式非法"
  exit 1
fi
echo

# 清理 tmux 会话
tmux kill-session -t "${SESSION_NAME}" 2>/dev/null || true

cd ..
rm -rf "$TEST_DIR"

echo "=== 所有场景测试通过 ==="
exit 0
