---
name: agent-bridge
description: "Use when 多 Agent 后台并行/角色扮演/委派外部 CLI (claude/codex). 统一封装多 Agent 调用与编排."
version: 1.0.0
platforms: [windows, linux, macos]
---

# Agent Bridge Skill

统一封装多 Agent 调用，把"角色库 → Claude/Codex 调用 → 后台并行 → 监控回收"封装为一套脚本与约定。

> **路线 A（v4.4.2 起）**：常规交付任务**默认走平台原生 worker**（看板卡 → dispatcher 派生 `hermes -p <profile>`），
> 不再默认 fork 外部 CLI。本技能现在的定位是：
> - `parallel` 子命令 = 任务文件 → **原生看板卡**（`scripts/kanban-dispatch.py`，三闸门 + 语义指纹幂等）
> - `claude` / `claude-bg` / `codex` = **可选后端**，仅在跨模型对比、需要 Codex 特定能力时使用
> 原生路径带心跳、崩溃回收、评审门与持久审计；外部 CLI 路径没有，用就得自己补状态回写。

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

**监控**：

```bash
bash agent-bridge.sh monitor --task-id t-001
# 实时显示日志尾部 + 当前状态
```

---

### 模式 3：批量并行（多任务不共写文件）

```bash
# 预览（只打印将执行的建卡命令，不落板）
bash agent-bridge.sh parallel --tasks tasks.yaml --dry-run

# 真派发：三道闸门全过才建卡（交给平台 dispatcher 执行）
bash agent-bridge.sh parallel --tasks tasks.yaml
```

> **实现说明（v4.4.2 起）**：`parallel` 不再由套件自己 fork `claude -p` 并维护
> `active.json`，而是转成**平台原生看板卡**（`scripts/kanban-dispatch.py`）。
> 三道闸门顺序执行，任一不过即拒发：
> 1. **环境闸门** `scripts/preflight.sh` —— hermes CLI / 看板可读写 / **dispatcher 是否存活** / python / 角色库；调度器未运行 → DEGRADED，只允许串行 + 人工对账
> 2. **边界闸门** `scripts/scope-check.py` —— 并行任务 `files_scope` 两两互斥校验，重叠或缺边界即拒发
> 3. **幂等闸门** —— `--idempotency-key` 用**语义指纹** `sha256(目标+边界+验收)`；平台语义是「同 key 的非归档卡已存在 → 返回既有卡 id，不新建」，因此重复子任务与重跑都不会双跑

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

**执行规则（v4.4.2 实测行为）**：
1. **环境闸门**：`preflight.sh`；DEGRADED（调度器未运行）时仍可建卡，但必须按制度层降级为串行 + 人工对账
2. **边界闸门**：`scope-check.py` 校验所有任务 `files_scope` 两两互斥，**重叠或缺边界即整体退出（退出码 1），不建任何卡**（部分建卡会造成半派发状态）
3. **幂等闸门**：每卡用语义指纹作 `--idempotency-key`，重跑/补账返回既有卡 id，不产生重复卡（实测：同指纹派发两次 → 同一 `t_xxxxxxxx`，板上仍 1 条）
4. **建卡即交付执行权**：卡默认 `ready`；不给 `--assignee` 时留在板上等人工/对账认领，给了 `--assignee <profile>` 则由平台 dispatcher 派生原生 worker 执行
5. **产物位置**：代码交付任务显式传 `--workspace worktree`（或给看板设 `default-workdir`）；平台默认 `scratch` 工作区**完成即删**，产物会丢
6. **执行后核对**：不依赖 stdout 自述，用 `hermes kanban list --json` / `kanban show <id>` 核对状态与证据

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