# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Claude Code Node Orchestration Platform** — a multi-agent (Multi-Agent) collaboration system based on a "Thin Agent / Fat Platform" architecture. Manus acts as the master Planner, dispatching tasks to remote Claude Code nodes via secure channels.

**Reference Architecture**: [Reddit: 39-agent orchestration platform on Claude Code](https://www.reddit.com/r/ClaudeAI/comments/1qxmybe/we_built_a_39agent_orchestration_platform_on/)

## Architecture

### Core Layers (top to bottom)
1. **Master Planner Layer** — Manus (local App/desktop) handles intent parsing, task decomposition, global state, and polling-based monitoring
2. **Remote Communication Layer** — SSH + `tmux` detached sessions for non-blocking remote execution
3. **Node Execution Layer** — Claude Code CLI in headless mode (`-p <prompt> --output-format json`), instantiated as role-specific Thin Agents
4. **Deterministic Constraint Layer** — Claude Code Lifecycle Hooks (`PreToolUse`, `PostToolUse`, `Stop`) bound to shell scripts for quality gates

### Roles & Tool Permissions (互斥矩阵)

| Role | allowedTools | disallowedTools |
|------|-------------|------------------|
| **Planner/Lead** | `Task`, `Read`, `Bash` (read-only) | `Edit`, `Write` |
| **Coder/Developer** | `Edit`, `Write`, `Read`, `Bash` (build/test) | `Task` |
| **Critic/Reviewer** | `Read`, `Bash` (lint/test) | `Edit`, `Write`, `Task` |

### Orchestration Modes
- **Subagents mode** (preferred) — for deep info retrieval, code review, isolated exploration. Subagent writes structured results to filesystem.
- **Agent Teams mode** (on-demand) — for complex refactoring with tightly coupled concurrency. Only activated in specific high-complexity scenarios due to high Token cost.

### Key Mechanisms
- **State anchoring**: Remote project root contains `claude-progress.json` or `MANIFEST.yaml`. Each Thin Agent reads this on spawn and only modifies its responsible `status` fields.
- **Quality gates**: Hooks intercept save/exit actions,强制运行 Lint/unit tests. Non-zero exit code blocks the Agent.
- **File locks**: `.lock` files with PID. Interrupt via `SIGINT` (not `SIGKILL`) to trigger graceful Checkpoint save.
- **Hard timeouts**: Use `timeout` command; probe scripts detect loops and report to master Planner.

## Skills

### ssh-remote-interaction.skill

ZIP archive containing SSH remote interaction scripts for node orchestration. Extracted contents:

| Script | Purpose |
|--------|---------|
| `scripts/init_sandbox.sh` | JIT environment setup (sshpass, tmux, jq, ControlMaster) |
| `scripts/cc_dispatch.sh` | Async Claude Code task dispatch via tmux detached session + lock file |
| `scripts/cc_probe.sh` | Lightweight status probe (minimal JSON <100 bytes, loop detection) |
| `scripts/cc_interrupt.sh` | Graceful interruption (SIGINT first, 15s grace period, then force kill) |
| `scripts/cc_dispatch.sh` | tmux daemon + lock file for async Claude Code dispatch |
| `scripts/download_manager.sh` | tmux守护异步下载 |
| `scripts/remote_exec.py` | Secure remote command execution |
| `scripts/sync_files.sh` | File synchronization |

**Core workflow**:
1. `init_sandbox.sh` — first step for any new task
2. Check lock file before dispatch (`orchestration.lock`)
3. Dispatch via `cc_dispatch.sh` → returns immediately (non-blocking)
4. Poll via `cc_probe.sh` (1-2 times max per task, not per minute)
5. Interrupt via `cc_interrupt.sh` before new dispatch if needed

## Project Status

### Phase 1 ✅ Complete
- `src/state_manager.js` — State manager with `initializeState()`, `updateTaskStatus()`, `readState()`. Uses `flock(1)` for concurrent write protection.
- `test/state_manager.test.js` — Concurrent update test (passes)

### Phase 2 ✅ Complete
- `.claude/settings.json` — Hooks configuration (`PostToolUse`, `Stop`)
- `scripts/set_dirty_bit.sh` — Sets dirty bit when Edit/Write is used (PostToolUse hook)
- `scripts/verify_before_exit.sh` — Quality gate: runs lint/tests before exit, blocks on failure (Exit Code 2)
- `test/verify_before_exit.test.sh` — Quality gate test (3 scenarios, all pass)
- `test/set_dirty_bit.test.sh` — Dirty bit test (3 scenarios, all pass)

### Phase 3 ✅ Complete
- `scripts/spawn_agent.sh` — Async task dispatch via tmux detached session + lock file (from skill)
- `scripts/probe_status.sh` — Lightweight status probe: minimal JSON, loop detection (from skill)
- `test/spawn_and_probe.test.sh` — Local tmux simulation test (4 scenarios, all pass)

### Phase 4 ✅ Complete
- `scripts/interrupt_agent.sh` — Graceful interruption: SIGINT first, 15s grace, then force kill, followed by Node.js state update (with Manus platform fallback).
- `test/interrupt.test.sh` — Local tmux simulation test (4 scenarios, all pass)

### All Phases Complete ✅

## Key File Meanings

| File | Purpose |
|------|---------|
| `setup.sh` | 自动化安装脚本 — 一键安装所有依赖 |
| `README.md` | 使用文档 — 快速开始、配置、迁移指南 |
| `src/state_manager.js` | State manager (Phase 1) — concurrent-safe claude-progress.json读写 |
| `test/state_manager.test.js` | State manager concurrent test (Phase 1) |
| `.claude/settings.json` | Claude Code hooks配置 (PostToolUse, Stop) |
| `scripts/set_dirty_bit.sh` | PostToolUse hook — Edit/Write 时设置 dirty bit |
| `scripts/verify_before_exit.sh` | Stop hook — 退出前强制 lint/tests，失败返回 Exit 2 |
| `scripts/spawn_agent.sh` | Async task dispatch via tmux (Phase 3) — 需要 SSH 远程执行 |
| `scripts/probe_status.sh` | 轻量状态探针，JSON <100 bytes (Phase 3) — 需要 SSH 远程执行 |
| `scripts/interrupt_agent.sh` | 优雅中断与状态同步: SIGINT→15s等待→SIGKILL，并自动更新状态为 interrupted (含平台端兜底) — 需要 SSH 远程执行 |
| `ssh-remote-interaction.skill` | ZIP archive with SSH orchestration scripts |
| `Claude_Code_Orchestration_PRD.md` | Product Requirements Specification |
| `Claude_Code_Orchestration_Architecture.md` | Architecture Design Document |
| `Claude Code CLI 节点化编排项目构想与规划.md` | Project Concept & Planning |
| `Claude Code 节点化编排：核心工程挑战与解决方案设计.md` | Core Engineering Challenges & Solutions |
| `Claude Code 节点化编排架构指南：基于 Anthropic 官方与社区验证的最佳实践.md` | Architecture Guide (Anthropic official + community best practices) |
| `Claude Code 节点化编排平台：项目开发计划 (PLAN).md` | Development Plan |

## External References

- [Claude Code Headless Mode](https://code.claude.com/docs/en/headless)
- [Claude Code Subagents](https://code.claude.com/docs/en/sub-agents)
- [Claude Code Hooks](https://code.claude.com/docs/en/hooks)
- [Shipyard: Multi-agent orchestration for Claude Code](https://shipyard.build/blog/claude-code-multi-agent/)
