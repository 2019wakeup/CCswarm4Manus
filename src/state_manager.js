/**
 * state_manager.js - 状态握手协议实现
 *
 * 管理 claude-progress.json 的读写，提供进程安全的并发控制。
 * 使用 flock(1) 实现跨进程文件锁。
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const os = require('os');

const STATE_FILENAME = 'claude-progress.json';
const LOCK_SUBDIR = '.locks';
const STATE_LOCK = 'state.lock';

const VALID_STATUSES = ['pending', 'running', 'passes', 'failed', 'interrupted'];

/**
 * 获取状态文件路径和锁文件路径
 * @param {string} [manusDir] - .manus 目录路径，默认 ./manus
 */
function getPaths(manusDir = './manus') {
  return {
    stateFile: path.join(manusDir, STATE_FILENAME),
    lockDir: path.join(manusDir, LOCK_SUBDIR),
    lockFile: path.join(manusDir, LOCK_SUBDIR, STATE_LOCK),
  };
}

/**
 * 确保锁目录存在
 */
function ensureLockDir(lockDir) {
  if (!fs.existsSync(lockDir)) {
    fs.mkdirSync(lockDir, { recursive: true });
  }
}

/**
 * 读取当前状态（无锁）
 */
function readStateRaw(stateFile) {
  if (!fs.existsSync(stateFile)) {
    return null;
  }
  const content = fs.readFileSync(stateFile, 'utf8');
  return JSON.parse(content);
}

/**
 * 在文件锁保护下执行原子更新操作
 * @param {string} lockFile - 锁文件路径
 * @param {string} stateFile - 状态文件路径
 * @param {string} scriptContent - 要执行的 JavaScript 脚本内容
 * @returns {Object} 脚本输出的 state 对象
 */
function withLockAndUpdate(lockFile, stateFile, scriptContent) {
  ensureLockDir(path.dirname(lockFile));

  // 创建临时脚本文件
  const tmpDir = os.tmpdir();
  const scriptFile = path.join(tmpDir, `sm_lock_${process.pid}_${Date.now()}.js`);

  fs.writeFileSync(scriptFile, scriptContent, 'utf8');

  try {
    // 使用 flock 锁定，执行 Node.js 脚本，再解锁
    const cmd = `flock -x ${lockFile} -c "node ${scriptFile}"`;
    const result = execSync(cmd, { encoding: 'utf8' });
    return JSON.parse(result.trim());
  } finally {
    // 清理临时脚本
    try { fs.unlinkSync(scriptFile); } catch (e) { /* ignore */ }
  }
}

/**
 * 初始化状态文件
 * @param {Array<{id: string, description: string}>} tasks - 任务列表
 * @param {string} [manusDir] - .manus 目录路径
 * @returns {{success: boolean, tasks: Array}}
 */
function initializeState(tasks, manusDir = './manus') {
  const { stateFile, lockDir } = getPaths(manusDir);

  const stateDir = path.dirname(stateFile);
  if (!fs.existsSync(stateDir)) {
    fs.mkdirSync(stateDir, { recursive: true });
  }
  ensureLockDir(lockDir);

  const now = new Date().toISOString();
  const taskEntries = tasks.map(t => ({
    id: t.id,
    description: t.description || '',
    status: 'pending',
    errorMsg: null,
    updated_at: now,
  }));

  const state = {
    version: '1.0',
    updated_at: now,
    tasks: taskEntries,
  };

  // 初始写入使用原子操作：先写临时文件再 rename
  const tmpFile = stateFile + '.tmp';
  fs.writeFileSync(tmpFile, JSON.stringify(state, null, 2), 'utf8');
  fs.renameSync(tmpFile, stateFile);

  return { success: true, tasks: taskEntries };
}

/**
 * 读取完整状态
 * @param {string} [manusDir] - .manus 目录路径
 * @returns {Object|null}
 */
function readState(manusDir = './manus') {
  const { stateFile } = getPaths(manusDir);
  return readStateRaw(stateFile);
}

/**
 * 更新指定任务的状态
 * @param {string} taskId - 任务 ID
 * @param {string} status - 新状态
 * @param {string} [errorMsg] - 错误信息（可选）
 * @param {string} [manusDir] - .manus 目录路径
 * @returns {{success: boolean, task: Object}}
 * @throws {Error} 如果 taskId 不存在或状态值非法
 */
function updateTaskStatus(taskId, status, errorMsg = null, manusDir = './manus') {
  if (!VALID_STATUSES.includes(status)) {
    throw new Error(`Invalid status: ${status}. Must be one of: ${VALID_STATUSES.join(', ')}`);
  }

  const { stateFile, lockFile } = getPaths(manusDir);

  const scriptContent = `
    const fs = require('fs');
    const stateFile = ${JSON.stringify(stateFile)};
    const taskId = ${JSON.stringify(taskId)};
    const status = ${JSON.stringify(status)};
    const errorMsg = ${JSON.stringify(errorMsg)};

    let state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    if (!state) {
      console.error('State file not found');
      process.exit(1);
    }

    const taskIndex = state.tasks.findIndex(t => t.id === taskId);
    if (taskIndex === -1) {
      console.error('Task not found: ' + taskId);
      process.exit(1);
    }

    const now = new Date().toISOString();
    state.tasks[taskIndex].status = status;
    state.tasks[taskIndex].updated_at = now;
    if (errorMsg !== null) {
      state.tasks[taskIndex].errorMsg = errorMsg;
    }
    state.updated_at = now;

    fs.writeFileSync(stateFile, JSON.stringify(state, null, 2), 'utf8');
    console.log(JSON.stringify(state));
  `;

  const updatedState = withLockAndUpdate(lockFile, stateFile, scriptContent);
  const updatedTask = updatedState.tasks.find(t => t.id === taskId);
  return { success: true, task: updatedTask };
}

module.exports = {
  initializeState,
  updateTaskStatus,
  readState,
  getPaths,
  VALID_STATUSES,
};
