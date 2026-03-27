#!/bin/bash
# verify_before_exit.test.sh — 测试 verify_before_exit.sh 质量门控

set -euo pipefail

# 计算绝对路径
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_ROOT/test_artifacts/verify_test"
SCRIPT_DIR="$PROJECT_ROOT/scripts"

echo "=== verify_before_exit.sh 质量门控测试 ==="
echo

# 清理并准备测试环境
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/.manus/logs"

cd "$TEST_DIR"

# 创建模拟的 package.json

# 创建模拟的 package.json
cat > package.json <<'EOF'
{
  "name": "test-project",
  "scripts": {
    "lint": "echo 'Lint passed' && exit 0",
    "test": "echo 'Tests passed' && exit 0"
  }
}
EOF

echo "场景 A: 有 dirty bit，验证应该通过"
echo "---"
touch .manus/.dirty
echo "test_file.js" > .manus/.dirty

# 模拟执行 verify_before_exit.sh
export DIRTY_BIT=".manus/.dirty"
export LOG_FILE=".manus/logs/verify.log"

bash "$SCRIPT_DIR/verify_before_exit.sh"
RESULT_A=$?
echo "Exit Code: $RESULT_A"
if [ $RESULT_A -eq 0 ]; then
  echo "✓ 场景 A 通过: dirty bit 存在时验证成功"
else
  echo "✗ 场景 A 失败: 预期 Exit Code 0，实际 $RESULT_A"
  exit 1
fi
echo

echo "场景 B: 无 dirty bit，放行退出"
echo "---"
rm -f .manus/.dirty
rm -f .manus/logs/verify.log

bash "$SCRIPT_DIR/verify_before_exit.sh"
RESULT_B=$?
echo "Exit Code: $RESULT_B"
if [ $RESULT_B -eq 0 ]; then
  echo "✓ 场景 B 通过: 无 dirty bit 时放行"
else
  echo "✗ 场景 B 失败: 预期 Exit Code 0，实际 $RESULT_B"
  exit 1
fi
echo

echo "场景 C: 有 dirty bit，lint 失败时应阻断"
echo "---"
touch .manus/.dirty
echo "bad_file.js" > .manus/.dirty

# 创建会失败的 lint
cat > package.json <<'EOF'
{
  "name": "test-project",
  "scripts": {
    "lint": "echo 'Lint failed!' && exit 1",
    "test": "echo 'Tests passed' && exit 0"
  }
}
EOF

set +e
bash "$SCRIPT_DIR/verify_before_exit.sh" 2>&1
RESULT_C=$?
set -e
echo "Exit Code: $RESULT_C"
if [ $RESULT_C -eq 2 ]; then
  echo "✓ 场景 C 通过: lint 失败时返回 Exit Code 2"
else
  echo "✗ 场景 C 失败: 预期 Exit Code 2，实际 $RESULT_C"
  exit 1
fi
echo

cd ..
rm -rf "$TEST_DIR"

echo "=== 所有场景测试通过 ==="
exit 0
