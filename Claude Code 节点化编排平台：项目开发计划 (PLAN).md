# Claude Code 节点化编排平台：项目开发计划 (PLAN)

**作者**：Manus AI
**日期**：2026年3月26日
**目标执行者**：Claude Code CLI

## 1. 计划概述

本计划基于《Claude Code 节点化编排平台 PRD》与《架构设计文档》，将整个系统的开发拆解为 4 个主要阶段（Phases）。每个阶段包含若干个具体任务（Tasks），每个任务均配备了明确的**验证标准（Verification Criteria）**。

Claude Code 作为执行者，在执行本计划时，必须严格遵循“测试驱动开发（TDD）”与“确定性验证”的原则：**在进入下一个任务前，必须确保当前任务的验证脚本/测试用例完全通过。**

---

## Phase 1: 基础设施与状态管理 (Infrastructure & State)

本阶段目标：建立远程环境的初始化机制，并实现全局状态文件（`claude-progress.json`）的读写规范，为后续的 Agent 调度提供状态锚点。

### Task 1.1: 开发沙箱即时初始化脚本 (`init_sandbox.sh`)
*   **目标**：编写 Bash 脚本，用于在远程 Linux 服务器上静默安装必要依赖并配置 SSH 环境。
*   **具体要求**：
    *   检查并静默安装 `sshpass`, `tmux`, `jq`。
    *   配置 `~/.ssh/config`，开启 `ControlMaster auto` 和 `ControlPersist 10m` 以复用连接。
    *   脚本需具备幂等性（重复执行不会报错或产生副作用）。
*   **验证标准 (Verification)**：
    *   运行 `./init_sandbox.sh` 返回 Exit Code 0。
    *   运行 `which tmux jq sshpass` 均能找到对应路径。
    *   检查 `~/.ssh/config` 包含预期的配置项。

### Task 1.2: 定义与实现状态握手协议 (`state_manager.js`)
*   **目标**：创建一个轻量级的 Node.js 模块，用于管理 `claude-progress.json` 的读写。
*   **具体要求**：
    *   实现 `initializeState(tasks)`: 初始化状态文件。
    *   实现 `updateTaskStatus(taskId, status, errorMsg)`: 更新特定任务的状态（如 `pending`, `running`, `passes`, `failed`）。
    *   必须处理并发写入时的文件锁（File Lock）问题，避免状态损坏。
*   **验证标准 (Verification)**：
    *   编写并运行测试用例 `node test_state_manager.js`。
    *   测试需模拟两个并发进程同时调用 `updateTaskStatus`，最终读取 JSON 文件确认状态未丢失且格式合法。

---

## Phase 2: 确定性质量门控 (Deterministic Hooks)

本阶段目标：利用 Claude Code 的生命周期 Hooks 机制，建立底层的代码质量防线，防止 Agent 提交未经验证的代码。

### Task 2.1: 配置项目级 Hooks (`.claude/settings.json`)
*   **目标**：在项目根目录创建 Claude Code 的配置文件，绑定验证脚本。
*   **具体要求**：
    *   配置 `PreToolUse` 钩子：当检测到工具为 `Bash` 且意图为执行敏感命令时（可选），进行拦截记录。
    *   配置 `PostToolUse` 钩子：当工具为 `Edit` 或 `Write` 时，触发本地的“脏位（dirty bit）”标记脚本。
    *   配置 `Stop` 钩子：当 Agent 尝试退出时，调用强制验证脚本。
*   **验证标准 (Verification)**：
    *   运行 `cat .claude/settings.json | jq '.hooks'` 能够正确解析出配置的 Hooks 结构。

### Task 2.2: 开发强制验证拦截脚本 (`verify_before_exit.sh`)
*   **目标**：编写供 `Stop` 钩子调用的 Bash 脚本，强制执行 Lint 和测试。
*   **具体要求**：
    *   读取“脏位”状态。如果代码被修改过，执行 `npm run lint` 和 `npm test`。
    *   如果测试失败，脚本必须返回 Exit Code 2（或其他非零错误码），并向标准输出（stdout）打印具体的错误日志，以此阻断 Claude Code 退出并迫使其继续修复。
*   **验证标准 (Verification)**：
    *   **测试场景 A**：制造一个语法错误的 JS 文件，运行 `./verify_before_exit.sh`，预期返回非零 Exit Code。
    *   **测试场景 B**：修复该错误，运行 `./verify_before_exit.sh`，预期返回 Exit Code 0。

---

## Phase 3: 异步调度与探针系统 (Async Orchestration & Probes)

本阶段目标：实现主 Planner（Manus）非阻塞下发任务的机制，并开发轻量级探针脚本以极低的 Token 成本汇报状态。

### Task 3.1: 开发 tmux 任务下发包装器 (`spawn_agent.sh`)
*   **目标**：编写 Bash 脚本，将 Claude Code 进程包裹在分离的 tmux 会话中运行。
*   **具体要求**：
    *   接收参数：`TaskID`, `Role` (Planner/Coder/Critic), `Prompt`。
    *   根据 `Role` 动态注入工具权限（例如 Coder 角色注入 `--allowedTools Edit,Write,Read,Bash --disallowedTools Task`）。
    *   使用 `tmux new-session -d` 启动，并将输出重定向至 `.manus/logs/{TaskID}.log`。
    *   记录 tmux 进程的 PID 到 `.manus/locks/{TaskID}.lock`。
*   **验证标准 (Verification)**：
    *   运行 `./spawn_agent.sh task_001 Coder "echo 'hello'"`。
    *   运行 `tmux ls` 预期能看到 `task_001` 会话（或会话已结束）。
    *   检查 `.manus/logs/task_001.log` 包含预期输出。
    *   检查 `.manus/locks/task_001.lock` 存在且包含有效 PID。

### Task 3.2: 开发轻量级状态探针 (`probe_status.sh`)
*   **目标**：编写脚本，定期解析 Agent 的执行日志，返回极简 JSON。
*   **具体要求**：
    *   读取 `.manus/logs/{TaskID}.log` 的最后 100 行。
    *   提取关键信息：是否出现死循环（重复相同错误）、预估 Token 消耗、当前是否还在运行。
    *   输出格式必须为严格的 JSON，例如：`{"task_id": "task_001", "status": "running", "loop_detected": false}`。
*   **验证标准 (Verification)**：
    *   准备一个模拟的死循环日志文件。
    *   运行 `./probe_status.sh mock_task`。
    *   预期输出的 JSON 能被 `jq` 成功解析，且 `loop_detected` 字段为 `true`。

---

## Phase 4: 异常接管与优雅中断 (Resilience & Interrupts)

本阶段目标：处理用户随时可能发起的打断请求，确保系统状态的一致性。

### Task 4.1: 开发优雅中断脚本 (`interrupt_agent.sh`)
*   **目标**：编写脚本，安全地终止正在运行的 Claude Code 任务。
*   **具体要求**：
    *   读取 `.manus/locks/{TaskID}.lock` 获取 PID。
    *   向该 PID 发送 `SIGINT` 信号（`kill -SIGINT <PID>`），促使 Claude Code 保存 Checkpoint。
    *   轮询等待（最多 10 秒）进程退出。若超时未退出，升级为 `SIGKILL` 强制终止。
    *   清理 Lock 文件，并在 `claude-progress.json` 中将该任务标记为 `interrupted`。
*   **验证标准 (Verification)**：
    *   启动一个模拟的长耗时进程并写入 lock 文件。
    *   运行 `./interrupt_agent.sh mock_task`。
    *   验证进程被成功终止，lock 文件被删除，状态文件被正确更新。

---

## 2. 交付与验收

当 Claude Code 完成上述所有 4 个 Phase 的任务，并确保每个 Task 的验证脚本（Verification）均能稳定返回 Exit Code 0 时，该节点化编排平台的核心基础设施即宣告完成。

主 Planner（Manus）随后即可利用这套基础设施，开始下发实际的业务开发任务。
