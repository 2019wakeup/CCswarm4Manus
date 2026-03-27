#!/bin/bash
# set_dirty_bit.test.sh — 测试 set_dirty_bit.sh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_ROOT/test_artifacts/dirty_bit_test"
SCRIPT_DIR="$PROJECT_ROOT/scripts"

echo "=== set_dirty_bit.sh 测试 ==="
echo

# 清理并准备测试环境
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/.manus/logs"

cd "$TEST_DIR"

echo "场景 1: Edit 工具应设置 dirty bit"
echo "---"
bash "$SCRIPT_DIR/set_dirty_bit.sh" "Edit,src/app.js"
if [ -f ".manus/.dirty" ]; then
  CONTENT=$(cat .manus/.dirty)
  if [ "$CONTENT" = "src/app.js" ]; then
    echo "✓ 场景 1 通过: Edit 工具正确设置 dirty bit"
  else
    echo "✗ 场景 1 失败: dirty bit 内容不正确: $CONTENT"
    exit 1
  fi
else
  echo "✗ 场景 1 失败: dirty bit 未创建"
  exit 1
fi
echo

echo "场景 2: Write 工具应追加到 dirty bit"
echo "---"
bash "$SCRIPT_DIR/set_dirty_bit.sh" "Write,src/utils.js"
CONTENT=$(cat .manus/.dirty | tr '\n' ' ')
if echo "$CONTENT" | grep -q "src/app.js" && echo "$CONTENT" | grep -q "src/utils.js"; then
  echo "✓ 场景 2 通过: Write 工具追加到 dirty bit (去重后)"
else
  echo "✗ 场景 2 失败: dirty bit 内容不正确: $CONTENT"
  exit 1
fi
echo

echo "场景 3: Read 工具不应设置 dirty bit"
echo "---"
ORIGINAL_CONTENT=$(cat .manus/.dirty)
bash "$SCRIPT_DIR/set_dirty_bit.sh" "Read,src/app.js"
NEW_CONTENT=$(cat .manus/.dirty 2>/dev/null || echo "")
if [ "$ORIGINAL_CONTENT" = "$NEW_CONTENT" ]; then
  echo "✓ 场景 3 通过: Read 工具未修改 dirty bit"
else
  echo "✗ 场景 3 失败: dirty bit 被意外修改"
  exit 1
fi
echo

cd ..
rm -rf "$TEST_DIR"

echo "=== 所有场景测试通过 ==="
exit 0
