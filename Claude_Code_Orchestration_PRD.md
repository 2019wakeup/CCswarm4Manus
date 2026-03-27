# Claude Code 节点化编排平台：产品需求规格说明书 (PRD)

**作者**：Manus AI
**日期**：2026年3月26日
**版本**：v1.0

## 1. 引言

### 1.1 项目背景
在日常的软件开发与复杂研究任务中，Claude Code 展现出了卓越的代码理解与编辑能力。然而，原生 Claude Code CLI 在全局规划、复杂信息检索以及长期运行的稳定性方面存在一定局限。为了突破单体 Agent 的能力瓶颈，本项目旨在构建一个**“主从架构”的多智能体（Multi-Agent）协作平台**。该平台将远程 Linux 服务器上的 Claude Code 节点化，由 Manus 作为主 Planner，通过安全通道下发任务并进行宏观调度。

### 1.2 目标与愿景
本项目的核心目标是实现**确定性的大规模 AI 辅助开发（Deterministic AI Development at Scale）**。通过引入“Thin Agent / Fat Platform”架构理念 [1]，结合严格的工具权限隔离与确定性质量门控（Hooks），彻底解决大语言模型在长上下文中出现的“能力衰减悖论（Context-Capability Paradox）”。最终交付一个支持多角色协作、具备自我纠错能力且高度稳定的生产级代码编排系统。

## 2. 核心概念与架构原则

### 2.1 Thin Agent / Fat Platform 架构
根据业界验证的最佳实践 [1]，系统摒弃将所有指令和上下文塞入单个庞大 Prompt 的传统做法：
*   **Thin Agent（轻量级执行节点）**：远程运行的 Claude Code 实例。每次任务均在干净的上下文窗口中启动（无状态、短生命周期），Prompt 长度严格控制在 150 行以内，从而大幅降低 Token 消耗并提升推理精准度。
*   **Fat Platform（重型调度平台）**：Manus 充当平台层，负责状态持久化、任务拆解、路由分发以及确定性约束的强制执行。

### 2.2 确定性约束与工具权限互斥
为防止 Agent 出现“越俎代庖”（例如架构师亲自编写代码而忽略规划）的现象，系统在底层实施互斥的工具权限管理 [1]：

| 角色 (Role) | 核心职责 | 允许的工具 (allowedTools) | 禁用的工具 (disallowedTools) |
| :--- | :--- | :--- | :--- |
| **Lead / Planner** | 架构设计、任务分解与委派 | `Task`, `Read`, `Bash` (只读) | `Edit`, `Write` |
| **Developer / Coder** | 代码实现与功能修复 | `Edit`, `Write`, `Read`, `Bash` (构建/测试) | `Task` |
| **Reviewer / Critic** | 代码审查与合规性检查 | `Read`, `Bash` (Lint/测试) | `Edit`, `Write`, `Task` |

### 2.3 官方编排模式的选择
基于 Anthropic 官方文档与社区经验 [2] [3]，系统将动态支持两种多 Agent 模式：
*   **Subagents 模式（首选）**：适用于深度信息检索、代码审查和隔离探索。主 Agent 派生 Subagent，Subagent 在隔离上下文中运行并将结构化结果写入文件系统，避免“传话游戏”导致的信息丢失。
*   **Agent Teams 模式（按需开启）**：适用于复杂重构或高度耦合的并发开发。通过共享任务列表协调多个“Teammates”，允许 Agent 间直接通信。因 Token 成本极高，仅在特定复杂场景下激活。

## 3. 功能需求详细说明

### 3.1 基础设施与环境管理 (Infrastructure & Environment)
*   **REQ-1.1: 沙箱即时初始化 (JIT Initialization)**
    *   **描述**：主 Planner（Manus）连接远程节点时，必须能在 5 秒内静默完成 SSH 免密配置、工具链安装（如 `sshpass`, `tmux`）及网络连通性测试。
*   **REQ-1.2: 远程状态锚定 (Remote State Anchoring)**
    *   **描述**：在远程项目根目录维护统一的状态文件（如 `.manus/orchestration_state.json` 或 `MANIFEST.yaml`）。主 Planner 每次重连后首要动作是读取该文件，瞬间恢复全局上下文 [1]。

### 3.2 异步调度与通信 (Asynchronous Orchestration)
*   **REQ-2.1: 非阻塞任务下发**
    *   **描述**：主 Planner 必须通过 `tmux` 的分离模式（Detached）下发 Claude Code 进程，结合 `--output-format json` 与 `--dangerously-skip-permissions` 参数实现无头（Headless）零阻塞运行 [4]。
*   **REQ-2.2: 结构化状态轮询 (Structured Polling)**
    *   **描述**：禁止主 Planner 直接读取冗长的执行日志。必须在远程部署探针脚本，定期解析日志并返回极简的 JSON 摘要（包含任务 ID、当前阶段、Token 消耗预估及最后错误），以节约主 Planner 的上下文窗口。

### 3.3 确定性质量门控 (Deterministic Quality Gates)
*   **REQ-3.1: 生命周期 Hooks 绑定**
    *   **描述**：利用 Claude Code 的 `PreToolUse`、`PostToolUse` 和 `Stop` Hooks 绑定 Shell 脚本 [1] [5]。
*   **REQ-3.2: 脏位检查与强制测试**
    *   **描述**：当 Coder 角色修改代码时触发“脏位（dirty bit）”。在尝试退出或提交前，Hook 将强制运行单元测试/Lint。若测试失败，通过 Bash 层面（如 Exit Code 2）直接阻断，强制 Agent 继续修复，杜绝未经验证的代码合入。

### 3.4 异常处理与防打断机制 (Resilience & Concurrency Control)
*   **REQ-4.1: 文件锁与单例控制**
    *   **描述**：引入基于 PID 的 `.lock` 文件机制。主 Planner 在下发新任务前必须检查锁状态。若需打断当前任务，必须发送 `SIGINT` 信号促使 Claude Code 保存 Checkpoint 并优雅退出，严禁暴力 Kill 导致文件损坏。
*   **REQ-4.2: 循环检测与强制熔断**
    *   **描述**：为每个子任务设置硬超时（Hard Timeout，如利用 `timeout` 命令）。同时，探针需检测日志中重复的错误模式，一旦判定 Agent 陷入死循环，立即上报异常并由主 Planner 接管。

## 4. 交互与工作流设计

一次典型的复杂特性开发工作流（16-Phase Workflow 的简化版 [1]）如下：

1.  **Setup & Discovery**：主 Planner 接收用户需求，下发指令给远程 Researcher 角色，分析依赖关系并生成架构草案。
2.  **Design & Approval**：主 Planner 将草案转化为具体的任务分解列表，写入 `claude-progress.json`。
3.  **Implementation**：主 Planner 唤起 Coder 角色（禁用 `Task` 权限），Coder 读取进度文件并开始编码。
4.  **Verification (Hooks)**：Coder 尝试保存时，底层 Hooks 触发自动化测试。失败则阻断，成功则进入下一步。
5.  **Review & Completion**：唤起 Critic 角色进行安全与规范审计，全部通过后更新状态文件，主 Planner 回收结果并向用户汇报。

## 5. 非功能性需求 (NFR)
*   **性能**：探针脚本的 JSON 状态生成耗时需小于 1 秒；主 Planner 单次轮询 Token 消耗控制在 100 以内。
*   **安全性**：严禁在 Agent Prompt 中硬编码 API Keys。敏感凭证必须通过环境变量或 JIT 注入方式提供给运行环境。
*   **可观测性**：所有远程节点的 Agent 行为必须有结构化日志留存，支持回溯审计。

## 6. 参考文献
[1] Praetorian_Security. "We built a 39-agent orchestration platform on Claude Code... here's the architecture for deterministic AI development at scale". Reddit r/ClaudeAI. https://www.reddit.com/r/ClaudeAI/comments/1qxmybe/we_built_a_39agent_orchestration_platform_on/
[2] Shipyard Team. "Multi-agent orchestration for Claude Code in 2026". https://shipyard.build/blog/claude-code-multi-agent/
[3] Anthropic. "Create custom subagents - Claude Code Docs". https://code.claude.com/docs/en/sub-agents
[4] Anthropic. "Run Claude Code programmatically - Claude Code Docs". https://code.claude.com/docs/en/headless
[5] Anthropic. "Automate with hooks - Claude Code Docs". https://code.claude.com/docs/en/hooks
