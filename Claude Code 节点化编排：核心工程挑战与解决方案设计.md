# Claude Code 节点化编排：核心工程挑战与解决方案设计

**Author**: Manus AI
**Date**: March 26, 2026

## 1. 引言

在构建“Manus 作为主 Planner，通过 SSH 调度远程 Linux 服务器上的 Claude Code 节点”这一双层 Agent 架构时，我们面临着沙箱生命周期、异步通信、上下文管理以及进程防打断等一系列严峻的工程挑战。本报告针对这些问题提出了深度的架构设计与解决思路。

## 2. 挑战一：Manus 沙箱环境的易失性

**问题描述**：Manus 每次开启新对话时，都会启动一个全新的沙箱（Sandbox）环境。这意味着本地的 SSH 配置、依赖工具（如 `sshpass`、`tmux` 的客户端配置）以及状态记忆在任务结束后都会丢失。

**解决方案：远程状态锚定与一键初始化**

*   **沙箱环境的即时初始化 (JIT Initialization)**：
    根据 `ssh-remote-interaction` Skill 的最佳实践，在每次新任务开始时，Manus 必须首选执行 `init_sandbox.sh` 脚本。该脚本负责静默安装必要的工具（如 `sshpass`）、配置 `~/.ssh/config`（开启 `ControlMaster` 连接复用，禁用 `StrictHostKeyChecking`），确保沙箱在 5 秒内具备免密、防阻塞的 SSH 连通能力。
*   **状态与记忆“云端化”（Remote Project Memory）**：
    绝对不能依赖 Manus 本地沙箱来保存项目状态。必须在远程 Linux 服务器的项目根目录下建立一个统一的状态文件（例如 `.manus/orchestration_state.json`）。Manus 每次连接后，第一步动作是 `cat` 读取该文件，从而瞬间恢复上一轮对话中中断的上下文。

## 3. 挑战二：异步通信与 Manus 上下文约束（Token 节约）

**问题描述**：Claude Code 在远程执行复杂任务时可能需要数小时。如果 Manus 通过 SSH 保持同步阻塞等待，不仅会超时，还会导致 Manus 的上下文窗口被无意义的控制台日志填满，浪费大量 Token。

**解决方案：基于 tmux 的守护进程与结构化轮询**

*   **完全异步的非阻塞下发**：
    Manus 通过 SSH 下发命令时，必须将 Claude Code 进程包裹在 `tmux` 会话中，并使用分离模式（Detached）。例如：
    `tmux new-session -d -s task_123 'claude -p "修复登录bug" --output-format json > .manus/logs/task_123.log 2>&1; echo $? > .manus/logs/task_123.exit'`
*   **Token 友好的状态轮询 (Structured Polling)**：
    Manus 绝不能直接读取完整的 `task_123.log`。相反，应在远程部署一个轻量级的 Python/Bash 探针脚本（例如 `probe_status.sh`）。Manus 只需执行该探针，探针会解析日志并返回极简的 JSON 摘要：
    ```json
    {
      "task_id": "task_123",
      "status": "running",
      "current_phase": "testing",
      "last_error": null,
      "token_usage_estimate": 15000
    }
    ```
    这种方式将每次状态检查的 Token 消耗从几千降低到几十。

## 4. 挑战三：防打断与进程识别

**问题描述**：当用户在手机端（Manus App）随时发问时，Manus 可能会尝试开启新的 Claude Code 实例。如果不加限制，可能会导致多个 Claude 实例并发修改同一个文件，或者旧进程被意外 Kill。

**解决方案：文件锁（File Lock）与幂等性调度**

*   **基于 PID 与 Lock 文件的单例模式**：
    在远程服务器的 `.manus/` 目录下引入严格的文件锁机制。当 `task_123` 启动时，写入 `orchestration.lock`（包含 PID 和 Task ID）。
*   **拦截与意图识别**：
    当 Manus 收到用户新请求（例如“先停一下，优先修另外一个 Bug”）时，Manus 的调度逻辑必须是：
    1. 检查 `orchestration.lock`。
    2. 如果存在活动进程，使用 `kill -SIGINT <PID>` 向 Claude Code 发送优雅中断信号（Claude Code 接收到 SIGINT 会触发 checkpoint 保存并退出，而不是直接损坏文件）。
    3. 确认进程退出并释放锁后，再启动新任务。
*   **目录级作用域隔离 (Directory Scoping)**：
    如果确实需要并行执行，必须在下发命令时通过 `--allowedTools` 或工作区配置，将不同的 Claude Code 实例严格限制在不同的子目录下（例如前端 UI 团队和后端 API 团队），从物理层面杜绝写冲突。

## 5. 额外工程思考：异常接管与“死锁”恢复

在无人值守的远程编排中，最可怕的是进程挂起（Hang）或陷入死循环（如 Claude Code 不断重复相同的错误操作）。

*   **超时与强制熔断 (Hard Timeout)**：
    为每个子任务设置合理的 TTL（Time-To-Live）。在 `tmux` 启动命令中包裹 `timeout` 命令（如 `timeout 3600s claude ...`）。一旦超时，系统强制终止进程，并将状态标记为 `timeout_failed`。
*   **无限循环检测 (Loop Detection)**：
    远程探针脚本可以监控 `.manus/logs/task_123.log` 的增长速度和重复模式。如果发现最近 50 行日志在过去 10 分钟内重复出现超过 3 次，探针应主动上报 `loop_detected` 异常，触发 Manus 的介入和重新规划（如清空上下文后重新下发更具体的 Prompt）。
*   **MCP 权限的动态降级**：
    如果某个 Agent 频繁导致构建失败，Manus 可以在下一次重启该节点时，动态修改其配置，剥夺其 `Bash` 执行权限，将其降级为只读的 Reviewer，从而控制爆炸半径。

## 6. 总结

要实现一个生产级的“Manus -> SSH -> Claude Code”编排系统，核心在于**放弃同步控制的幻想，全面拥抱基于文件系统的异步状态机**。

Manus 的角色不应是“实时监工”，而应是“项目经理”：它通过 SSH 扔下一份包含任务目标、验收标准（Hooks/Tests）和隔离沙箱的“公文包”（tmux session），然后离开；定期通过探针脚本收取极简的进度报告（JSON）；并在任务偏离轨道时，通过发送信号（SIGINT）进行优雅干预。
