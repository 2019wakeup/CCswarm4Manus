/**
 * state_manager.test.js - 并发更新测试
 *
 * 验证两个并发进程同时调用 updateTaskStatus 时，状态文件不会损坏。
 */

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const STATE_MANAGER_PATH = path.join(__dirname, '..', 'src', 'state_manager.js');
const TEST_DIR = path.join(__dirname, '..', 'test_artifacts');

function setupTestDir() {
  if (!fs.existsSync(TEST_DIR)) {
    fs.mkdirSync(TEST_DIR, { recursive: true });
  }
  const manusDir = path.join(TEST_DIR, '.manus');
  if (fs.existsSync(manusDir)) {
    fs.rmSync(manusDir, { recursive: true, force: true });
  }
  fs.mkdirSync(manusDir, { recursive: true });
  return manusDir;
}

function runWorker(manusDir, taskId, status) {
  return new Promise((resolve, reject) => {
    const code = `
      const sm = require('${STATE_MANAGER_PATH}');
      const result = sm.updateTaskStatus('${taskId}', '${status}', null, '${manusDir}');
      console.log(JSON.stringify(result));
    `;

    const child = spawn('node', ['-e', code], {
      cwd: TEST_DIR,
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', d => stdout += d);
    child.stderr.on('data', d => stderr += d);

    child.on('close', code => {
      console.log(`      Worker stderr: ${stderr.trim().substring(0, 200)}`);
      resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() });
    });
    child.on('error', reject);
  });
}

async function main() {
  console.log('=== State Manager 并发测试 ===\n');

  const manusDir = setupTestDir();
  console.log(`测试目录: ${manusDir}\n`);

  // 1. 初始化状态文件
  console.log('1. 初始化状态文件...');
  const initCode = `
    const sm = require('${STATE_MANAGER_PATH}');
    const result = sm.initializeState([
      { id: 'task_001', description: '测试任务1' },
      { id: 'task_002', description: '测试任务2' },
    ], '${manusDir}');
    console.log(JSON.stringify(result));
  `;

  const initResult = JSON.parse(require('child_process').execSync(`node -e "${initCode.replace(/"/g, '\\"')}"`, { cwd: TEST_DIR, encoding: 'utf8' }));
  console.log(`   初始化结果: ${JSON.stringify(initResult.success)}\n`);

  // 2. 并发更新两个任务
  console.log('2. 并发更新两个任务...');
  const [result1, result2] = await Promise.all([
    runWorker(manusDir, 'task_001', 'running'),
    runWorker(manusDir, 'task_002', 'passes'),
  ]);

  console.log(`   Worker1 (task_001 -> running): exitCode=${result1.code}`);
  console.log(`   Worker2 (task_002 -> passes): exitCode=${result2.code}\n`);

  // 3. 验证状态文件未损坏
  console.log('3. 验证状态文件...');
  const stateFile = path.join(manusDir, 'claude-progress.json');
  let state;
  try {
    state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    console.log('   ✓ JSON 格式合法');
  } catch (e) {
    console.error('   ✗ JSON 格式损坏!');
    process.exit(1);
  }

  // 4. 验证任务状态正确
  const task1 = state.tasks.find(t => t.id === 'task_001');
  const task2 = state.tasks.find(t => t.id === 'task_002');

  console.log(`   task_001 状态: ${task1?.status} (预期: running)`);
  console.log(`   task_002 状态: ${task2?.status} (预期: passes)`);

  if (task1?.status !== 'running' || task2?.status !== 'passes') {
    console.error('\n   ✗ 状态值不正确!');
    process.exit(1);
  }
  console.log('   ✓ 状态值正确\n');

  // 5. 验证 updated_at 被正确更新
  if (state.updated_at) {
    console.log(`   ✓ updated_at 已更新: ${state.updated_at}\n`);
  }

  console.log('=== 所有测试通过 ===');
  process.exit(0);
}

main().catch(e => {
  console.error('测试失败:', e);
  process.exit(1);
});
