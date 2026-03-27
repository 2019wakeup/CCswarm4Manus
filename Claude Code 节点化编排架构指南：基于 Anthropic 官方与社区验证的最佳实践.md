# Claude Code 节点化编排架构指南：基于 Anthropic 官方与社区验证的最佳实践

**Author**: Manus AI
**Date**: March 26, 2026

## 1. 引言

在构建“Claude Code CLI 节点化编排”项目时，采用社区验证且获得 Anthropic 官方背书的架构模式至关重要。基于 Anthropic 的工程博客（如多 Agent 研究系统 [1]、长运行 Agent 编排 [2]）以及社区（如 Praetorian 的 39 Agent 平台 [3] 和 Shipyard 的多 Agent 编排对比 [4]）的实践，我们重新梳理了该项目的核心架构与最佳实践。

本报告摒弃了低活跃度的边缘开源项目，转而采用**“官方特性组合 + 确定性工程约束”**的架构思路，旨在为 Manus 作为主 Planner 调度远程 Claude Code 节点提供最可靠的落地方案。

## 2. 核心架构设计：Thin Agent / Fat Platform

根据 Praetorian 团队在 53 万行代码库上的实践 [3]，传统的“将所有指令塞入单个庞大 Prompt”的做法会导致“上下文-能力悖论（Context-Capability Paradox）”。因此，我们推荐采用 **"Thin Agent / Fat Platform"** 架构：

*   **Thin Agent（轻量级 Agent）**：每个 Claude Code 实例保持极简（Prompt 不超过 150 行），无状态且生命周期短暂。每次启动都是干净的上下文窗口，避免历史尝试污染。
*   **Fat Platform（重型平台）**：Manus 作为主 Planner（Platform），负责管理状态、任务分解和确定性约束。

### 2.1 角色互斥与权限隔离

为了防止 Agent “越俎代庖”（例如 Planner 亲自写代码），必须在系统层面实施**互斥的工具权限**：

| 角色 | 核心职责 | 允许的工具 (allowedTools) | 禁用的工具 |
| :--- | :--- | :--- | :--- |
| **Lead / Planner** | 架构设计、任务分解与委派 | `Task` (生成 Subagents), `Read`, `Bash` (只读) | `Edit`, `Write` |
| **Developer / Coder** | 代码实现 | `Edit`, `Write`, `Read`, `Bash` (构建/测试) | `Task` |
| **Reviewer / Critic** | 代码审查与合规性检查 | `Read`, `Bash` (Lint/测试) | `Edit`, `Write`, `Task` |

*注：如果一个 Agent 拥有 `Task` 工具，它将被物理剥夺 `Edit/Write` 权限；反之亦然 [3]。*

## 3. 官方编排模式选择：Agent Teams vs Subagents

Anthropic 官方在 Claude Code 中提供了两种原生的多 Agent 模式 [4]。作为 Manus 调度的底层节点，我们应根据任务类型动态选择：

### 3.1 Subagents (子代理模式)
*   **机制**：主 Agent 通过 `Task` 工具（旧版为 `Agent` 工具）派生 Subagent。Subagent 在隔离的上下文中运行，完成后仅向主 Agent 返回总结 [4]。
*   **适用场景**：深度信息检索、代码审查、隔离环境下的探索。
*   **最佳实践**：为了防止“传话游戏（Game of Telephone）”导致的信息丢失，Subagent 应直接将结构化结果写入文件系统（如 JSON 或 Markdown），仅向主 Agent 返回文件路径和简短状态 [1]。

### 3.2 Agent Teams (团队模式)
*   **机制**：通过设置 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS="1"` 开启。一个会话作为“Team Lead”，通过共享任务列表协调多个“Teammates”。Teammates 拥有独立的上下文，且可以**直接相互通信** [4]。
*   **适用场景**：复杂重构、需要并发处理的模块化开发。
*   **资源消耗**：极高。每个 Teammate 都是一个独立实例，Token 消耗呈倍数增长。

**项目建议**：在初期，建议 Manus 主要利用 **Subagents 模式** 进行节点编排，因为它更容易通过标准 MCP 接口或 SSH 命令进行状态追踪和结果回收。

## 4. 解决“长运行 Agent”的上下文衰减

Anthropic 官方指出，Agent 性能随上下文窗口的填满而显著下降 [2]。为了让远程 Claude Code 节点能长时间稳定运行，必须引入以下机制：

### 4.1 初始化环境与进度追踪 (The Harness)
*   **初始化脚本 (`init.sh`)**：Manus 在下发任务前，应在远程服务器生成环境初始化脚本，确保服务可运行。
*   **进度文件 (`claude-progress.json`)**：不依赖 Claude 的记忆，而是维护一个外部的 JSON 状态文件。文件包含所有待办功能（初始标记为 `passes: false`）。每次新启动的 Coder Agent 必须先读取该文件，并仅修改状态字段 [2]。

### 4.2 确定性质量门控 (Deterministic Backpressure)
*   **Hook 机制**：不要依赖大模型自己检查代码质量。利用 Claude Code 的生命周期 Hooks（如 `PreToolUse`, `PostToolUse`, `Stop`）绑定 Shell 脚本 [3]。
*   **脏位检查**：如果 Agent 编辑了代码，Hook 会设置一个“脏位（dirty bit）”。当 Agent 尝试退出或提交时，Hook 强制运行测试。如果测试失败，从 Bash 层面直接阻断，强制 Agent 继续修复。

### 4.3 验证驱动开发 (Verification-Driven)
*   Anthropic 官方最佳实践强调：**“给 Claude 提供验证自己工作的方法是你能做的最高杠杆的事情”** [5]。
*   Manus 在下发任务给 Coder 时，必须同时提供测试脚本或验证标准。例如，不要说“修复登录 Bug”，而是说“运行 `npm test auth`，修复失败的用例直到测试通过”。

## 5. 结论与下一步实施建议

通过放弃复杂的第三方通信框架，转而采用 **Manus (SSH) + 原生 Claude Code (Headless/Subagents) + 确定性 Hooks** 的架构，我们可以构建一个高度稳定、可扩展的节点化编排系统。

**第一阶段实施建议：**
1.  **开发 Manus SSH 适配器**：编写 Skill，使 Manus 能通过 SSH 发送带有 `--allowedTools` 和 `-p` (Headless) 参数的 `claude` 命令。
2.  **实现状态文件规范**：定义 `claude-progress.json` 的 Schema，作为 Manus 与远程 Claude 节点之间的标准握手协议。
3.  **配置确定性 Hooks**：在远程节点的 `.claude/settings.json` 中配置强制测试与 Linting 的 Hook，建立质量防线。

---

## References
[1] Anthropic Engineering. (2025). How we built our multi-agent research system. https://www.anthropic.com/engineering/multi-agent-research-system
[2] Anthropic Engineering. (2025). Effective harnesses for long-running agents. https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
[3] Praetorian_Security. (2026). We built a 39-agent orchestration platform on Claude Code... here's the architecture for deterministic AI development at scale. Reddit r/ClaudeAI. https://www.reddit.com/r/ClaudeAI/comments/1qxmybe/we_built_a_39agent_orchestration_platform_on/
[4] Shipyard Team. (2026). Multi-agent orchestration for Claude Code in 2026. https://shipyard.build/blog/claude-code-multi-agent/
[5] Anthropic. (2026). Best Practices for Claude Code. Claude Code Docs. https://code.claude.com/docs/en/best-practices
