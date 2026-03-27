# Claude Code 节点化编排平台：架构设计文档

**作者**：Manus AI
**日期**：2026年3月26日
**版本**：v1.0

## 1. 架构概述

本项目旨在解决单体大模型在复杂代码库中的上下文衰减与能力退化问题。我们采用 **Thin Agent / Fat Platform** 架构范式 [1]，将全局规划、状态管理和质量门控上移至“平台层（Manus）”，而将具体的代码生成、审查和信息检索下放至轻量级、无状态的“执行节点（Claude Code CLI）”。

这种主从架构（Master-Worker Architecture）不仅实现了计算资源的物理分离（本地/手机端发号施令，远程服务器执行繁重任务），还通过确定性的工程约束确保了 AI 生成代码的生产级质量。

## 2. 核心架构分层

系统整体分为四个逻辑层，自上而下协同工作：

### 2.1 主控规划层 (Master Planner Layer)
*   **核心组件**：Manus (App/桌面端)
*   **职责**：
    *   接收用户自然语言指令，进行意图理解与宏观任务拆解。
    *   维护全局项目状态，将复杂任务分解为可由单一特定角色执行的微任务。
    *   通过轮询探针脚本监控远程执行状态，并在出现死循环或异常时进行接管与重新规划。

### 2.2 远程通信层 (Remote Communication Layer)
*   **核心组件**：SSH 远程交互模块 (`ssh-remote-interaction` Skill)
*   **职责**：
    *   建立免密、幂等的安全 SSH 通道。
    *   执行沙箱的即时初始化（JIT Initialization），在 5 秒内就绪环境。
    *   通过 `tmux` 分离模式（Detached Session）非阻塞地下发 Claude Code 进程，解决网络波动与长耗时任务导致的连接断开问题。

### 2.3 节点执行层 (Node Execution Layer)
*   **核心组件**：Claude Code CLI (Headless Mode)
*   **职责**：
    *   以无头模式运行（`claude -p <prompt> --output-format json`）[2]，接收结构化指令并返回 JSON 格式结果。
    *   **角色实例（Thin Agents）**：根据主 Planner 下发的 `allowedTools`，实例化为特定的角色（如 Coder、Reviewer）。每个实例的 Prompt 严格限制在 150 行以内，且为无状态启动（Stateless Spawn）[1]。
    *   **动态编排**：优先使用 Subagents 模式进行任务委派与隔离执行；在极端复杂的并发场景下，按需开启 Agent Teams 模式 [3] [4]。

### 2.4 确定性约束层 (Deterministic Constraint Layer)
*   **核心组件**：Claude Code Lifecycle Hooks + Shell Scripts
*   **职责**：
    *   **拦截与校验**：利用 `PreToolUse`、`PostToolUse` 和 `Stop` 钩子，将 LLM 的行为与底层的 Bash 脚本绑定 [5]。
    *   **质量门控（Quality Gates）**：当 Coder 尝试提交修改或退出时，强制触发 Lint 和单元测试。如果测试失败，脚本返回非零退出码（如 Exit Code 2），直接在系统层面阻断 LLM 的操作，强制其继续修复 [1]。

## 3. 核心机制设计

### 3.1 状态持久化与上下文恢复
由于 Thin Agent 是无状态且生命周期短暂的，系统绝不依赖 Claude Code 自身的记忆功能。
*   **全局状态文件**：在远程项目根目录维护 `claude-progress.json`。
*   **握手协议**：每次启动新的 Agent 实例时，第一步必须是读取该状态文件。Agent 仅被允许修改其负责任务的 `status` 字段（如从 `pending` 改为 `passes`）。

### 3.2 权限隔离与互斥矩阵
为了防止 Agent 角色越界，系统在启动命令中强制注入工具权限约束 [1]：

| 实例化角色 | 启动参数示例 (伪代码) | 行为边界 |
| :--- | :--- | :--- |
| **Planner** | `--allowedTools Task,Read,Bash --disallowedTools Edit,Write` | 只能生成 Subagents 和读取文件，绝对无法直接修改代码。 |
| **Coder** | `--allowedTools Edit,Write,Read,Bash --disallowedTools Task` | 专注于实现当前模块，无法将任务外包给其他 Agent。 |
| **Critic** | `--allowedTools Read,Bash --disallowedTools Edit,Write,Task` | 只能运行测试脚本和审查代码，提出修改意见。 |

### 3.3 防打断与并发控制
*   **文件锁（File Lock）**：引入 `orchestration.lock`，记录当前运行的 Task ID 与 PID。
*   **优雅中断**：当主 Planner 接收到用户的新指令需要打断当前任务时，通过 `kill -SIGINT <PID>` 向 Claude Code 发送中断信号。Claude Code 捕获信号后会触发内部的 Checkpoint 机制，安全保存当前进度并退出，避免文件损坏。

## 4. 数据流与交互时序

以下为处理一个复杂特性（Feature）的典型时序流：

1.  **[Manus]** 解析用户需求，生成架构设计与任务清单。
2.  **[Manus]** 通过 SSH 写入 `claude-progress.json`（标记所有子任务为未完成）。
3.  **[Manus]** 通过 SSH + tmux 启动 **Coder Agent**（注入对应的 Prompt 和权限）。
4.  **[Coder Agent]** 读取进度文件，开始修改代码。
5.  **[Coder Agent]** 尝试保存/退出。
6.  **[Hooks Layer]** 拦截退出动作，执行 `npm test`。
    *   *若失败*：阻断退出，将错误日志喂给 Coder，强制重试。
    *   *若成功*：允许保存。
7.  **[Probe Script]** 定期解析日志，发现 Coder 任务完成。
8.  **[Manus]** 轮询获取到完成状态，关闭 Coder Agent。
9.  **[Manus]** 启动 **Critic Agent** 进行代码审查，通过后更新全局状态，最终向用户汇报。

## 5. 部署拓扑与资源评估

*   **平台端 (Manus)**：负责低频高价值的规划与调度，Token 消耗极低。
*   **远程节点 (Linux Server)**：
    *   依赖：Node.js 环境，Claude Code CLI 最新版。
    *   存储：需预留充足的磁盘空间用于存放 `.manus/logs`（建议配置日志轮转）。
    *   计算：由于采用 Thin Agent 模式，每次 Spawn 消耗从数万 Token 降至约 2,700 Token [1]，极大优化了 API 成本。

## 6. 参考文献
[1] Praetorian_Security. "We built a 39-agent orchestration platform on Claude Code... here's the architecture for deterministic AI development at scale". Reddit r/ClaudeAI. https://www.reddit.com/r/ClaudeAI/comments/1qxmybe/we_built_a_39agent_orchestration_platform_on/
[2] Anthropic. "Run Claude Code programmatically - Claude Code Docs". https://code.claude.com/docs/en/headless
[3] Shipyard Team. "Multi-agent orchestration for Claude Code in 2026". https://shipyard.build/blog/claude-code-multi-agent/
[4] Anthropic. "Create custom subagents - Claude Code Docs". https://code.claude.com/docs/en/sub-agents
[5] Anthropic. "Automate with hooks - Claude Code Docs". https://code.claude.com/docs/en/hooks
