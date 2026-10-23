---
name: agent-bridge
description: "Use when 多 Agent 后台并行/角色扮演/委派外部 CLI (claude/codex). 统一封装多 Agent 调用与编排."
version: 1.0.1
platforms: [windows, linux, macos]
---

# Agent Bridge Skill

统一封装多 Agent 调用，把"角色库 → Claude/Codex 调用 → 后台并行 → 监控回收"封装为一套脚本与约定。

> 适用场景：需要调用外部 AI CLI（Claude Code / Codex）执行编码任务；多任务并行不共写文件；用角色库切换 Agent 身份。
> 不适用场景：单任务用 Print 模式即可（直接 `claude -p`）；端到端跑通用 pipeline（用 autonomous-delivery）。

---

## 入口与触发

```bash
# 列出可用角色
bash .hermes/scripts/agent-bridge.sh roles

# 单任务调用（角色扮演）
bash .hermes/scripts/agent-bridge.sh claude backend-developer "实现用户登录 API"

# 后台并行（多任务）
bash .hermes/scripts/agent-bridge.sh parallel --tasks tasks.yaml

# 监控后台任务
bash .hermes/scripts/agent-bridge.sh monitor --task-id t-001
```

**触发词**：「bridge 调用」「后台并行」「角色扮演」「多 Agent 编排」

---

## 角色库（与 Hermes 16 通用角色联动）

调用时通过角色名自动加载对应角色定义：

```bash
# 列出所有可用角色
bash agent-bridge.sh roles
# 输出：
#   backend-developer   通用后端开发（跨语言自适应）
#   frontend-developer  通用前端开发（Vue/React/小程序自适应）
#   dba                 数据库设计与优化
#   devops              CI/CD 与部署
#   test-engineer       测试（单测/集成/E2E）
#   code-reviewer       通用代码审查
#   architect           架构决策
#   ...

# 调用时自动读取 .hermes/通用角色库/<role>.md 作为 system prompt
```

**角色定义路径**：
- Claude Code：`.hermes/通用角色库/<role>.md`（必须存在，否则报错）
- Codex：`~/.codex/agents/<role>.md`（可选）

---

## 调用模式

### 模式 1：单任务 Print 模式（首选）

```bash
bash agent-bridge.sh claude <role> "<任务>"
# 等价于：
#   claude -p "<角色提示词>+任务" --allowedTools "..." --max-turns 10
```

**实现细节**：
1. 读取 `.hermes/通用角色库/<role>.md` 作为 system prompt
2. 把角色提示词 + 任务拼接为输入
3. 调用 `claude -p` 执行
4. 输出 JSON 格式结果（含 session_id/cost/turns）

**示例**：

```bash
bash agent-bridge.sh claude backend-developer \
  "在 src/auth/ 下实现用户登录 API。要求：
   1. POST /api/auth/login，body 为 {email, password}
   2. 返回 JWT token
   3. 错误处理完整（401/403/500）
   4. 加单元测试"
```

---

### 模式 2：后台运行（异步）

```bash
bash agent-bridge.sh claude-bg <role> "<任务>" --task-id t-001
# 后台启动 claude，记录到 ~/.workbuddy/agent-bridge/tasks/t-001/
```

**输出**：

```
Task started: t-001
  PID: 12345
  Log: ~/.workbuddy/agent-bridge/tasks/t-001/claude.log
  Status: ~/.workbuddy/agent-bridge/tasks/t-001/status.json
  Output: ~/.workbuddy/agent-bridge/tasks/t-001/output.json
```

**收割器（run.sh，2026-10-15 B 方案）**：claude-bg 不裸起 claude，而是起 `<task_dir>/run.sh` 包装层——
claude 退出（无论成败）必把 status.json 改写为 `completed`/`failed` + exit_code + finished_at。
status.json 里的 `pid` 是收割器的 PID，它全程存活直到 claude 退出，所以「pid_alive 判活」与
「status.json 终态」两条信号一致（旧版只在启动时写 running，claude 完成后状态永远停留 →
没有任何唤醒源，S5/S6 断链——这是本收割器要解决的问题）。kanban-watchdog 对未确认终态报
`BRIDGE_LANE_DONE`，驱动巡检 agent 验收续接；**验收闭环走完才准 `touch <task_dir>/ack` 清信号**
（详见 `kanban-executor` §2）。
**同步提醒**：改项目 `.hermes/scripts/agent-bridge.sh` / `kanban-watchdog.py` 后，若 cron/其它入口从
`HERMES_HOME/scripts/` 读同名脚本，必须同步拷贝并 md5 核对（实测曾三处副本不同步、改动静默失效）。
**验信号探针的路径坑**：用 `AGENT_BRIDGE_TASK_BASE=<scratch>` 手跑 kanban-watchdog.py 验证
`BRIDGE_LANE_DONE` 时，环境变量必须是 Windows 原生路径（`C:/...`）——喂 MSYS/POSIX 路径
（`/c/...`、`$TMPDIR`）时脚本 `is_dir()` 判定失败会**静默跳过**整个 bridge 段，输出只剩 `BOARD` 一行，
看起来像「信号没生效」，实则是路径没被识别。探针输出为空先查路径，再怀疑逻辑。

**监控**：

```bash
bash agent-bridge.sh monitor --task-id t-001
# 实时显示日志尾部 + 当前状态
```

---

### 模式 3：批量并行（多任务不共写文件）

```bash
bash agent-bridge.sh parallel --tasks tasks.yaml
```

**tasks.yaml 格式**：

```yaml
tasks:
  - id: t-001
    role: backend-developer
    task: "实现用户登录 API"
    workdir: /path/to/project
    files_scope:
      - src/auth/
      - tests/auth/
    max_turns: 10

  - id: t-002
    role: frontend-developer
    task: "实现登录页面组件"
    workdir: /path/to/project
    files_scope:
      - src/components/Login.vue
    max_turns: 10

  - id: t-003
    role: dba
    task: "设计 users 表结构"
    workdir: /path/to/project
    files_scope:
      - migrations/
      - docs/db/
    max_turns: 8
```

**执行规则**：
1. 校验所有任务 files_scope **互不重叠**（重叠则报错退出）
2. 并行启动（Hermes `delegate_task` 多任务 或多个 `terminal(background=true)`）
3. 每个任务单独 worktree
4. 监控每个任务状态
5. 所有任务完成后 Fan-In 汇总
6. 任何一个任务失败 → 整体报告失败，用户决定是否回滚

---

### 模式 4：Codex 调用（备选模型）

```bash
bash agent-bridge.sh codex <role> "<任务>"
# 调用 codex 而非 claude
```

**适用场景**：
- 跨模型对比验证（claude 与 codex 结果对比）
- cost 优化（codex 在某些任务上更便宜）
- 模型互补（claude 擅长推理，codex 擅长实现）

**注意**：codex CLI 不完全兼容 claude 的 flags，agent-bridge 自动适配。

---

## 派发前必须去重（claude-bg 双写事故）

`claude-bg` **不是幂等的**：同一 `--task-id` 重复调用会起第二个 claude 进程，**两个 Agent 同时改同一批文件**（无锁、无冲突检测，最后落盘的是谁赢不确定），而 `status.json` 只记录后一个 PID，前一个变孤儿继续跑。

**多任务连续派发时最易踩的坑：命令行里的 `--task-id` 与 `cat` 的派发文件对不上。** 一条一条复制上一条命令改参数时，很容易只改了文件名而忘了改 `--task-id`（实测：把同一张任务书配了同一个 `--task-id` 派了两遍，两次间隔 55 秒，靠 `Get-CimInstance` 比对 CreationDate 才发现）。**每条 claude-bg 命令发出前，把 `--task-id` 的值与派发文件名里的任务号对一遍**，或干脆用变量：`ID=<卡号>; FILE=<派发文件>`，命令行里只引用变量，不手写 ID。

派发前先查在跑的任务，确认没有同 task_id 的 claude 进程：

```bash
bash agent-bridge.sh list                    # active.json 里的活跃任务
cat ~/.workbuddy/agent-bridge/tasks/<task-id>/status.json   # 已有则看 pid / state
```

**判断"我的任务还活着吗"不能数 `tasklist | grep -ci claude`**——多项目并行时别的仓库/别的会话的 claude.exe 也会被数进去（实测：本项目任务跑着 1 个，全局看是 2 个，另一个属于另一个仓库的任务），由此误判成"双写事故"而误杀别的任务。按 PID 精确判定：

```bash
# 本任务真正的 claude.exe：父进程是你派发时的 sh.exe —— 用父命令行认领
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"name='claude.exe'\" | ForEach-Object { \$p=\$_.ProcessId; \$pp=(Get-CimInstance Win32_Process -Filter \"ProcessId=\$(\$_.ParentProcessId)\").CommandLine; [PSCustomObject]@{Pid=\$p;Parent=\$_.ParentProcessId;Mine=(\$pp -like '*tasks/<task-id>*')} } | Format-Table -AutoSize"
```

`Mine=True` 的那一行才是你的。注意 `tasks/<task-id>/pid` 记的是 agent-bridge 那边的 shell PID，**不是** claude.exe 的 PID，两者不可混用。

- 命令发出去后**不要凭「好像没起来」就重发**——后台启动本身可能只是输出被你漏看（转义错误会让 echo 出来的命令行与实际执行的不一致，更难判断）。重发前必须 `list` + `tasklist` 核过。
- 已误起两个：`taskkill //PID <后起的> //F`（git-bash 下要双斜杠），**只杀后起的**，前一个才是写入方；杀完立刻 `git status` + `git diff` 核对落盘内容是否为单一来源。

---

> **任务传递姿势与委派失败升级机制**：详见 `AGENTS.md §六.5` 与 `AGENTS.md §六.7`，本 SKILL 不重复。

---

## 状态目录结构

```
~/.workbuddy/agent-bridge/
├── tasks/
│   ├── t-001/
│   │   ├── claude.log        # 实时日志
│   │   ├── status.json       # 当前状态（running/done/failed）
│   │   ├── output.json       # 最终输出（JSON 格式）
│   │   └── diff.patch        # 代码改动 diff（如果有）
│   └── t-002/
├── failures.log              # 失败模式汇总
└── active.json               # 当前活跃任务清单
```

---

## 命令速查

| 操作 | 命令 |
|------|------|
| 列出角色 | `bash agent-bridge.sh roles` |
| 单任务 Print | `bash agent-bridge.sh claude <role> "<task>"` |
| 单任务后台 | `bash agent-bridge.sh claude-bg <role> "<task>" --task-id t-NNN` |
| 批量并行 | `bash agent-bridge.sh parallel --tasks tasks.yaml` |
| 监控任务 | `bash agent-bridge.sh monitor --task-id t-NNN` |
| 列出活跃任务 | `bash agent-bridge.sh list` |
| 终止任务 | `bash agent-bridge.sh kill --task-id t-NNN` |
| Codex 调用 | `bash agent-bridge.sh codex <role> "<task>"` |

---

## 与其他技能配合

| 场景 | 配合技能 |
|------|---------|
| 七阶段流程中的派发 | `project-workflow`（S4 拆任务后用 agent-bridge 派发） |
| 看板任务派发 | `kanban-executor`（建卡后用 agent-bridge 派给编码 Agent） |
| 改码前波及面评估 | `codegraph-review`（先评估再委派） |
| 端到端自动化 | `autonomous-delivery`（用 agent-bridge 作为底层调用） |

---

> **红线**：详见 `AGENTS.md §九` Agent 十条军规——不亲自改代码 / 不吞错 / 不跳验证 / 不重复失败。本 SKILL 不重复。

---

## 部署

详见 `DEPLOY.md §5`。

---

> 版本信息见仓库根 `CHANGELOG.md`（不再每个文件单独记录）。