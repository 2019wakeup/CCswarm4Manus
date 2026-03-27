# Claude Code 节点化编排平台 (CCswarm4Manus)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Claude Code](https://img.shields.io/badge/Claude_Code-2026-blue.svg)](https://code.claude.com)
[![Architecture](https://img.shields.io/badge/Architecture-Thin_Agent_/_Fat_Platform-success.svg)]()

**CCswarm4Manus** 是一个专为 [Manus](https://manus.im)（作为主 Planner）调度的多智能体（Multi-Agent）协作系统。本项目基于 Anthropic 官方推荐的 **"Thin Agent / Fat Platform"** 架构，旨在提供一种极其稳定、抗上下文衰减、且具备确定性质量约束的远程节点化编排方案。

## 🌟 核心理念与架构

随着 Agent 执行任务的复杂度和时间增加，将所有工具和中间状态塞入单个上下文窗口会导致严重的“上下文膨胀（Context Bloat）”和能力下降。

本项目通过以下架构解决此问题：
* **Fat Platform (Manus 主控端)**：负责意图解析、任务拆解、宏观状态管理。通过极轻量的 SSH Skill 异步下发任务，不阻塞自身上下文。
* **Thin Agent (远程执行节点)**：利用 Claude Code CLI 的无头模式（Headless），每个子任务启动一个干净的、无历史包袱的 Agent 实例，在隔离的 `tmux` 环境中闭环执行。
* **确定性质量门控 (Hooks)**：不依赖大模型自我检查，而是通过底层的生命周期钩子（Pre/PostToolUse, Stop）强制执行 Lint 和单元测试。测试失败则从底层阻断退出，强制修复。

## ✨ 核心特性

1. **零阻塞异步调度**：基于 `tmux` 守护进程，Manus 下发任务后立即释放，实现真正的分布式异步计算。
2. **轻量级状态探针**：通过 `<100 bytes` 的极简 JSON 探针获取远程状态，包含死循环检测，极大节省 Token 消耗。
3. **并发安全的状态管理**：使用 `flock` 机制保护 `claude-progress.json`，确保多 Agent 并发读写状态时的最终一致性。
4. **优雅中断与状态同步**：支持发送 `SIGINT` 信号优雅打断任务（给 Claude Code 15秒保存 Checkpoint），并具备节点端与平台端双重状态兜底更新机制。
5. **基于角色的权限隔离**：严格的工具互斥矩阵（如 Coder 拥有 `Edit/Write` 权限但禁用 `Task` 派生权限），防止 Agent 越权操作。

---

## 🔧 环境要求 (Requirements)

在使用本项目前，请确保远程执行节点满足以下版本要求：

| 依赖 | 最低版本 | 说明 |
| :--- | :--- | :--- |
| **Claude Code CLI** | **>= v2.1.71** | 低于此版本的 Hooks 格式不兼容，会导致 settings.json 解析失败 |
| **Node.js** | >= v18 | state_manager.js 依赖 Node.js 运行时 |
| **tmux** | >= 3.0 | 异步守护进程，用于后台运行 Claude Code 节点 |
| **jq** | >= 1.6 | 轻量 JSON 状态解析，probe_status.sh 依赖 |
| **flock** | 任意版本 | 并发安全文件锁，通常随 util-linux 预装 |

> **注意**：可运行  自动检查并安装所有依赖，安装完成后会自动进行版本兼容性校验。


## 🚀 快速开始

### 1. 环境准备 (远程节点/本地开发机)

克隆项目后，在项目根目录运行一键安装脚本：

```bash
# 自动安装 node, tmux, jq, sshpass, flock 以及配置 hooks
bash setup.sh
```

*如果 Claude Code CLI 未安装，脚本会提示安装方法。*

### 2. Manus 侧配置 (主控端)

Manus 仅需加载本项目提供的 `ssh-remote-interaction.skill` 即可驱动整个系统。
在与 Manus 的对话中，提供远程服务器的 SSH 凭证，并下达指令：

> *"Manus，请连接到我的远程服务器 `user@host`，在 `~/projects/my-app` 目录下，帮我重构一下数据库连接池。"*

Manus 会自动：
1. 运行沙箱初始化脚本准备环境。
2. 拆解任务，通过 SSH 调用 `cc_dispatch.sh` 唤起远程 Claude Code。
3. 在后台静默监控探针，直到底层 Hooks 测试通过，向你汇报最终成果。

---

## 📂 目录结构

```text
CCswarm4Manus/
├── src/
│   └── state_manager.js       # 核心状态管理器（Node.js），处理并发安全的 JSON 读写
├── scripts/
│   ├── spawn_agent.sh         # 异步任务下发（需要 SSH）
│   ├── probe_status.sh        # 状态探针（需要 SSH）
│   ├── interrupt_agent.sh     # 优雅中断与状态同步（需要 SSH）
│   ├── set_dirty_bit.sh       # PostToolUse Hook：代码修改后标记脏位
│   └── verify_before_exit.sh  # Stop Hook：退出前强制运行测试
├── .claude/
│   └── settings.json          # Claude Code Hooks 配置文件
├── test/                      # 核心组件的自动化测试用例
├── ssh-remote-interaction.skill # 供 Manus 使用的 SSH 交互技能包
└── setup.sh                   # 环境一键初始化脚本
```

---

## 🛠️ 核心组件使用示例

### 状态管理器 (`src/state_manager.js`)
作为整个系统的“真相来源（Single Source of Truth）”：

```javascript
const sm = require('./src/state_manager');

// 初始化任务列表
sm.initializeState([
  { id: 'task_001', description: '实现用户认证' }
], './manus');

// 更新状态（带并发锁保护）
sm.updateTaskStatus('task_001', 'running', null, './manus');
```

### 远程任务下发与探针
*注意：这些脚本通常由 Manus 的 Skill 自动调用，无需人工干预。*

```bash
# 1. 异步下发任务
bash scripts/spawn_agent.sh user@server "task_001" "实现用户登录功能" ~/project "Edit,Write,Read,Bash"

# 2. 探针查询（预估时间后轮询，切勿高频调用）
bash scripts/probe_status.sh user@server task_001 ~/project

# 3. 优雅中断任务（自动更新状态文件，支持平台端兜底）
bash scripts/interrupt_agent.sh user@server task_001 ~/project "user_preemption"
```

---

## 🧪 自动化测试

项目包含了完整的测试套件，确保核心基础设施的稳定性：

```bash
# 运行所有测试
node test/state_manager.test.js
bash test/verify_before_exit.test.sh
bash test/set_dirty_bit.test.sh
bash test/spawn_and_probe.test.sh
bash test/interrupt.test.sh
```

---

## ❓ 常见问题 (FAQ)

**Q: 为什么不使用 MCP (Model Context Protocol) 进行远程编排？**
A: 在“云端调度物理机”的场景下，传统的 MCP 会导致严重的上下文膨胀（Context Bloat），并且跨网络通信成本高。本项目的 `Skill + SSH` 方案通过在远程闭环执行任务，仅返回极简探针结果，是目前最节省 Token、最抗上下文衰减的架构实践。

**Q: macOS 下提示 `flock: command not found`？**
A: macOS 默认未安装 `flock`。请运行 `brew install flock`，或直接执行 `bash setup.sh` 自动修复。

**Q: 如何配置 SSH 连接复用以加速调度？**
A: `setup.sh` 会自动配置 `~/.ssh/config`。确保 `~/.ssh/sockets` 目录存在，并检查配置中是否包含 `ControlMaster auto`。

---

## 📚 参考资料

- [Anthropic: Code execution with MCP - Building more efficient agents](https://www.anthropic.com/engineering/code-execution-with-mcp)
- [Anthropic: Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
- [Claude Code Headless Mode](https://code.claude.com/docs/en/headless)
- [Shipyard: Multi-agent orchestration for Claude Code](https://shipyard.build/blog/claude-code-multi-agent/)
