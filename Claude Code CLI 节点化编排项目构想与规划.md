# Claude Code CLI 节点化编排项目构想与规划

**作者**：Manus AI
**日期**：2026年3月25日

## 1. 项目背景与愿景

在日常的开发与研究中，Claude Code 展现出了强大的代码理解与编辑能力。然而，原生的 Claude Code 在全局规划能力以及联网搜索信息整合方面存在一定局限性。为了充分发挥不同 AI 系统的优势，本项目提出了一种**“主从架构”的多智能体协作模型**：将部署在远程 Linux 服务器上的 Claude Code CLI 节点化，并通过 Model Context Protocol (MCP) 将其能力暴露出来。

在此架构下，**Manus**（或其他具备强大规划和搜索能力的 Agent）作为**主 Planner**，可以通过手机端或本地终端随时发起任务。主 Planner 负责高层级的任务拆解、信息检索与策略制定，并通过 SSH 通道调用远程服务器上的 Claude Code MCP 节点。而在远程节点内部，则充分激发 Claude Code 的 Agent Teams（Swarm）能力，动态编排多个角色（如 Coder, Researcher, Critic）协同完成具体的代码或研究任务。

这种设计不仅弥补了 Claude Code 规划能力的不足，还实现了计算资源的分离与移动端办公的灵活性。

## 2. 系统架构设计

本系统的核心在于将分布式的组件通过标准协议无缝连接。整体架构分为四个逻辑层：

### 2.1 架构分层

1. **主控规划层 (Master Planner Layer)**
   - **组件**：Manus App / 桌面端
   - **职责**：接收用户自然语言指令，进行意图理解、复杂任务规划、前置信息检索（Web Search），并将具体任务下发给远程节点。
2. **远程通信层 (Remote Communication Layer)**
   - **组件**：SSH 远程交互模块
   - **职责**：基于极致精简的 SSH 交互最佳实践 [1]，建立安全、高效、幂等的远程连接，管理远程服务器的项目状态与环境初始化。
3. **协议适配层 (Protocol Adapter Layer)**
   - **组件**：Claude Code MCP Server
   - **职责**：将 Claude Code CLI 封装为标准的 MCP 工具。利用 Claude Code 的 Headless 模式（`-p` 或 `--print` 参数，配合 `--output-format json`），将非交互式的命令行输出转化为结构化的 MCP 响应 [2] [3]。
4. **节点执行层 (Node Execution Layer)**
   - **组件**：Claude Code CLI (Swarm/Agent Teams)
   - **职责**：接收结构化 Prompt，利用内部的 Task 系统与 TeammateTool，动态生成多个 Subagents 或 Agent Teams，在独立的上下文窗口中并行执行任务 [4] [5]。

### 2.2 架构交互图

| 发起端 | 传输层 | 代理层 | 执行层 (Swarm) |
| :--- | :--- | :--- | :--- |
| **Manus (主 Planner)** | SSH 通道 | **Claude Code MCP Server** | **Team Lead (Claude)** |
| 负责：全局规划、信息整合 | 负责：安全指令下发 | 负责：指令解析、JSON格式化 | 负责：任务分配、结果合成 |
| | | | ↳ **Coder Agent** (代码编写) |
| | | | ↳ **Critic Agent** (代码审查) |
| | | | ↳ **Researcher Agent** (方案调研) |

## 3. 多 Agent 角色划分与动态组合

为了让远程节点高效运作，必须在 Claude Code 内部建立严格的角色边界。根据官方的 Agent Teams 规范 [4]，每个 Teammate 都在独立的上下文窗口中运行，通过共享任务列表（Shared Task List）和直接消息（Teammate Messaging）进行协作。

### 3.1 核心角色定义

通过预设不同的 System Prompt 和工具权限（Tools Permissions），我们可以定义以下基础角色：

- **Planner (节点级)**：由 Claude Code 的 Team Lead 担任。负责接收 Manus 下发的宏观任务，将其拆解为子任务（TaskCreate），并分配给具体的 Worker。
- **Coder**：拥有完整的读写权限（Bash, Read, Write）。专注于根据详细的架构设计编写代码、修改文件。
- **Critic**：拥有只读权限（Explore, Read）。作为“魔鬼代言人”，专注于安全审计、性能评估、测试覆盖率检查以及代码规范审查。
- **Researcher**：拥有搜索与分析权限（Explore, WebSearch）。专注于在庞大的代码库中寻找依赖关系，或阅读特定框架的本地文档。

### 3.2 任务驱动的动态组合模式

根据 Manus 下发的任务类型，Claude Code 节点可以动态组合这些角色，形成特定的“特遣队”（Swarm）：

1. **代码开发任务组合**：`[节点 Planner] + [Coder] + [Critic]`
   - *工作流*：Planner 分解模块 -> Coder 并行实现不同模块 -> Critic 独立进行代码审查 -> Planner 综合审查意见要求 Coder 修改 -> 最终提交。
2. **深度信息检索与分析组合**：`[节点 Planner] + [Researcher A] + [Researcher B] + [Critic]`
   - *工作流*：针对复杂 Bug 或架构调研，派生多个 Researcher 提出相互竞争的假设（Competing Hypotheses）[4]。Critic 负责寻找假设中的漏洞，最终由 Planner 总结出最可靠的结论。
3. **重构与测试组合**：`[节点 Planner] + [Coder (Refactor)] + [Coder (Test)]`
   - *工作流*：一个 Agent 负责重构遗留代码，另一个 Agent 并行编写对应的单元测试，两者通过消息机制对齐接口规范。

## 4. 核心实施路径

要实现上述构想，建议按照以下三个阶段进行推进：

### Phase 1: 基础设施构建 (SSH + MCP Server)

1. **配置 SSH 交互模块**：复用现有的 `ssh-remote-interaction` 技能，确保主 Planner 能够免密、幂等地在远程 Linux 服务器上执行命令。
2. **开发 Claude Code MCP Wrapper**：
   - 使用 Node.js 或 Python 编写一个轻量级的 MCP Server（可参考开源实现如 `steipete/claude-code-mcp` [6]）。
   - 暴露核心工具：`run_claude_code(prompt, tools, team_mode)`。
   - 底层调用：使用 `claude -p <prompt> --output-format json --dangerously-skip-permissions` 实现非交互式调用与结构化结果返回 [2]。

### Phase 2: Swarm 编排协议定义

1. **配置 Team 模板**：在远程服务器的 `~/.claude/teams/` 目录下，或者通过 `.claude.json` 预设不同角色的配置参数 [5]。
2. **设计任务 Prompt 模板**：为主 Planner 设计一套 Prompt 模板，使其在调用 MCP 工具时，能够明确指示 Claude Code 启动 Team 模式。例如：
   > "创建一个 Agent Team 来解决这个问题。生成一个 Coder 负责实现，一个 Critic 负责审查。要求 Critic 在 Coder 提交计划前进行强制审批（Plan Approval）。"

### Phase 3: 主控逻辑与容错机制闭环

1. **状态轮询与异步守护**：由于 Agent Teams 运行耗时较长，MCP 工具应支持异步触发。主 Planner 可以通过 `tmux` 配合状态检查工具，定期获取远程任务的执行进度 [1]。
2. **异常接管机制**：当 Critic 发现无法解决的代码冲突，或 Coder 陷入死循环时，Claude Code Team Lead 应抛出明确的错误 JSON。主 Planner 接收到错误后，利用其更强的全局搜索能力寻找解决方案，并重新下发修复指令。

## 5. 最佳实践与注意事项

- **Token 成本控制**：Agent Teams 中每个 Teammate 都拥有独立的上下文窗口，Token 消耗会线性增加 [4]。因此，**仅在需要并行探索、深度审查或独立假设时使用 Teams**；对于简单的线性任务，应退级使用单体会话或 Subagents [7]。
- **避免文件冲突**：在动态组合 Coder 时，必须在 Planner 的指令中明确划分每个 Coder 的**文件作用域**，防止多个 Agent 同时修改同一个文件导致覆写（Race Conditions）[4]。
- **记忆与状态保持**：远程服务器的交互容易丢失上下文。必须在项目根目录维护一个 `CLAUDE.md`，用于持久化项目架构、当前进度和核心规范。每次新任务启动时，所有 Teammate 都会自动加载该文件作为初始上下文 [4]。
- **零阻塞执行**：在远程无人值守环境中，必须配置 `--allowedTools` 或预设权限，避免 Claude Code 弹出交互式确认提示而导致进程挂起 [2]。

---

## 参考文献

[1] Manus AI, "SSH 远程交互技能 (极致精简版)", 本地技能文档.
[2] Anthropic, "Run Claude Code programmatically - Claude Code Docs", https://code.claude.com/docs/en/headless.
[3] M. K., "How to create a Claude MCP server", Medium, Feb 2026.
[4] Anthropic, "Orchestrate teams of Claude Code sessions - Claude Code Docs", https://code.claude.com/docs/en/agent-teams.
[5] K. Klaassen, "Claude Code Swarm Orchestration Skill", GitHub Gist, Jan 2026.
[6] P. Steinberger, "claude-code-mcp: Claude Code as one-shot MCP server", GitHub Repository, https://github.com/steipete/claude-code-mcp.
[7] Anthropic, "Create custom subagents - Claude Code Docs", https://code.claude.com/docs/en/sub-agents.
