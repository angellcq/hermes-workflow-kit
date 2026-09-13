---
name: kanban-executor
description: "Use when 看板任务需要自动认领/巡检/回收. Kanban 任务生命周期自动化."
version: 1.0.0
platforms: [windows, linux, macos]
---

# Kanban Executor Skill

自动管理 Hermes Kanban 任务生命周期：未认领分配、心跳保活、超时回收、状态验证闭环。

## 核心能力

### 0. 建卡派发（S4 唯一入口 · 双闸门 + 幂等）

**任何任务在写 TASK.md / 建 worktree / 派发编码代理之前，必须先过闸门并 `kanban-dispatch` 上板。**
TASK.md 里的"当前状态"字段仅是缓存，看板才是唯一事实源；**未上板的卡不会有任何机制兜底**
（dispatcher 只认板上卡），只写 TASK.md 不上板 = 漏板失职。

标准顺序（命令照抄，勿即兴发挥）：

```bash
# ① 环境闸门：hermes CLI / 看板 / 调度器存活 / python / 角色库
bash .hermes/scripts/preflight.sh
#    DEGRADED（调度器未运行）→ 禁止并行派发：降级为串行 + 人工对账，并显式上报用户

# ② 边界闸门：并行任务 files_scope 两两互斥（重叠或缺边界即拒发，退出码 1）
python .hermes/scripts/scope-check.py --tasks tasks.yaml --json
#    输出里的 fingerprints 就是下一步要用的幂等键

# ③ 建卡（语义指纹作 --idempotency-key；命令输出会打印每张卡的 t_xxxxxxxx）
python .hermes/scripts/kanban-dispatch.py --tasks tasks.yaml \
  --assignee <profile> --workspace worktree --branch claude
#    ↑ 平台语义：同 key 的非归档卡已存在 → 返回既有卡 id，不新建
#      （实测：同指纹派发两次 → 同一 t_xxxxxxxx，板上仍 1 条 = 天然防重复执行）
#    ↑ 代码交付务必显式 --workspace worktree：平台默认 scratch 工作区完成即删，产物会丢

# ④ 准出证据（硬闸门）：上一步输出的 id 列表就是 S4 准出证据；
#    缺任一 t_xxxxxxxx = S4 未准出，禁止进入 S5、禁止声称"任务已创建到看板"

# ⑤ 执行后收口：完成验证闭环后回板
hermes kanban complete <id> --summary "<验收结论>" --metadata '{"commit":"<hash>","changed_files":[...]}'
```

约束：
- 标题前缀 = 任务卡 ID（`T-003: ...`），看板 ↔ 任务卡双向可回溯
- `--idempotency-key` 一律用**语义指纹**（`scope-check.py --json` 的 `fingerprints`），
  补账/重跑天然去重；**禁止**改用人工命名（人工命名无法识别语义重复）
- worker 侧通过 `kanban_show` / `kanban_heartbeat` / `kanban_complete` 等 **kanban_* 工具**操作看板，
  不是 shell 出去调 `hermes kanban`（平台已把生命周期注入 worker 上下文）
- **会话收尾自查**：diff `.hermes/tasks/` 新增 TASK.md 与本会话建卡 id 清单，
  发现漏板的当场补建并回补状态，禁止留给下次
- 已合并的漏板历史任务补账：`create --initial-status running` 后立刻 `complete --summary "<commit+验收结论>"`；
  未验收完的建卡后 `block <id> "<待办原因>"`，不许默默留在 ready

### 1. 悬空卡处置 (Auto-Claim)

**平台已自带认领**：dispatcher 会给 `ready` 且**已指派**的卡派生 worker（原子认领，不会双跑）。
本节只处理剩下的一种情况——**`ready` 且无人认领**的悬空卡：

```bash
# 找出 ready + 无 assignee 的卡
hermes kanban list --json | python -c "import sys,json; [print(f\"{t['id']} {t['title'][:50]}\") for t in json.load(sys.stdin) if t['status']=='ready' and not t.get('assignee')]"

# 指派给某个 profile（此后交回平台调度）
hermes kanban assign <task_id> <profile>
```

**执行策略：**
- body/任务卡信息完整 → 直接指派；信息不完整 → 先补 body（`kanban comment` 追加来源与边界）再指派
- 无调度器（preflight 为 DEGRADED）时不要指望自动认领：按制度层降级为**串行人工执行**

### 2. 心跳与长任务 (Heartbeat)

平台规则（事实源，不要再自造巡检周期）：
- worker 侧用 `kanban_heartbeat` 续命；`hermes kanban heartbeat <id> --note "..."` 供外部脚本/人工续命
- **running 超过 4 小时且 1 小时内无心跳 → dispatcher 回收该卡并重排（不计失败）**
- 因此：预计 >1 小时的任务必须把"每小时心跳"写进任务卡要求，否则会被静默回收重派

```bash
hermes kanban runs --active <task_id>     # 查看运行记录
hermes kanban heartbeat <task_id> --note "长任务续命：仍在跑编译"
```

### 3. 超时与熔断回收（平台接管，勿叠加）

| 情形 | 平台行为 | 触发开关 |
|------|---------|---------|
| 连续失败 N 次 | 自动 `block`（熔断） | `--max-retries N`（默认取 dispatcher `failure_limit` = 2） |
| 单卡运行超时 | SIGTERM（不退则 SIGKILL）并重排队 | `--max-runtime 30m/2h/1d` |
| running 卡 >4h 且 1h 无心跳 | 回收重排（不计失败） | 平台默认 |
| worker 崩溃/协议违规 | bounded retry（默认 3 次）后自动 block | 平台默认 |

**处理流程**（人工介入只发生在熔断之后）：
1. `hermes kanban show <id>` 看阻塞原因与历史事件
2. 代码逻辑错 → 修 TASK.md/边界后 `hermes kanban unblock <id>` 重新交回平台
3. 环境/网络问题 → `hermes kanban reclaim <id>` 后重派
4. 确实做不下去 → 保持 `block`，写清`需人工介入：XXX` 并上报

### 4. 完成验证闭环

编码代理完成任务后，必须验证产出再标记完成；**「完成」优先绑定到 PR/CI 硬门，而不是自述**：

```
1. git diff --stat HEAD                  # 确认有变更
2. 项目编译/测试命令通过                  # 编译、单测、集成
3. 核对 changed_files                     # 与任务卡 files_scope 一致（越界即违规）
4. 提交评审：hermes kanban request_review <id>
   （建卡时给了 --completion-contract <OWNER/REPO | PR URL> 的卡，由平台校验 PR/CI 门全绿才允许 done）
5. 评审通过 → hermes kanban complete <id> --summary "..." --metadata '{"commit":"...","changed_files":[...]}'
   评审退回 → hermes kanban request_changes <id> --body "<需改点>"（闭环上限 2 轮，第 3 轮上浮协商）
```

**零产出判定：** `git status --short` 和 `git diff --stat HEAD` 均为空 → 委派失败 → STOP 转手动 patch，**不得**标记完成。

**幂等重复检查：** 若建卡时同语义指纹的卡已存在（平台返回既有 id），说明这是重复子任务——直接复用既有卡的结论，**不得重复执行**。

### 5. 归档、保留与监控（平台能力，勿自建）

**归档纪律**：卡必须先到终态（`done` / `blocked`）再 `hermes kanban archive <id>`；
归档期**不得**再触发重试或重派（归档是终态，挂起重试会与之冲突——先 `unblock` 再动手）。

**保留/清理**（平台 `gc`，默认保留 30 天）：

```bash
hermes kanban gc --event-retention-days 30 --log-retention-days 30   # 清事件与 worker 日志
```

**监控指标**（用平台数据，不另建监控表）：

```bash
hermes kanban stats --json           # 各状态计数 / 积压与完成量
hermes kanban watch --kinds completed,blocked,gave_up,crashed,timed_out   # 事件流
hermes kanban notify-subscribe ...   # done/blocked/changes_requested 通知
```

| 要监控的东西 | 平台来源 | 判断 |
|------|---------|------|
| 重复执行（同一语义任务多卡） | 建卡幂等键 = 语义指纹；`kanban list --json` 查同 key | 出现重复卡 → 指纹未用/被改写，立刻纠正 |
| 调度可用性 | `preflight.sh` + `kanban stats` 心跳新鲜度 | 调度器未运行 → 立即降级串行并上报 |
| 状态冲突 | `kanban show <id>` 的事件序列 | 出现跳级流转 → 流程违规，回溯补记 |
| 卡滞/积压 | `stats` 里 `ready`/`blocked` 计数 | `blocked` 超一个检查周期 → 升级协商 |

## 命令速查

| 操作 | 命令 |
|------|------|
| **建卡（S4 第一步，见 §0）** | `hermes kanban create "T-NNN: <标题>" --body "..." --workspace worktree --branch claude/<slug> --idempotency-key T-NNN --initial-status running --json` |
| 查看未分配任务 | `hermes kanban list --json` 过滤 ready+null assignee |
| 分配任务 | `hermes kanban assign <id> <profile>` |
| 查看任务详情 | `hermes kanban show <id>` |
| 标记完成 | `hermes kanban complete <id> --summary "..."` |
| 标记阻塞 | `hermes kanban block <id> "reason"` |
| 查看运行中 | `hermes kanban runs --active` |

## 在工作流中的位置与配合

本技能是**执行层的任务生命周期管理者**，不负责拆需求、不改码。

- **上游**：`project-workflow` 在 S4 阶段拆出任务卡后，交给本技能建卡派发（顺序固定为 **§0 建卡上板 → 写 TASK.md → 认领**，禁止先写 TASK.md 后补卡）
- **下游**：编码代理（Claude Code/Codex）产出后，本技能做**完成验证闭环**（git diff 非空 + 编译通过 + changed_files 核对），通过才标 DONE
- **旁路**：`codegraph-review` 在编码代理改码**之前**被调用评估波及面，评估报告作为任务卡附件
- **兜底**：巡检与派发由平台负责——dispatcher 默认跑在 gateway 进程里（认领 ready 卡、回收崩溃/stale 任务、连续失败自动 block）。
  **派发前必须 `preflight.sh` 确认调度器存活**；未运行时不再假装有兜底，而是显式降级为「单 Agent 串行 + 人工对账」并上报用户。
  （套件不提供独立的 watchdog cron——历史文档提到的 `kanban-board-watchdog` 从未落地，已删除该声明）

**调用时机**：只要看板出现 ready/blocked/超时任务，或 S4 需要建卡派发，就加载本技能。
