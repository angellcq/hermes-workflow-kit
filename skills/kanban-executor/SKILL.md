---
name: kanban-executor
description: "Use when 看板任务需要自动认领/巡检/回收. Kanban 任务生命周期自动化."
version: 1.1.0
platforms: [windows, linux, macos]
---

# Kanban Executor Skill

自动管理 Hermes Kanban 任务生命周期：派发路由、认领复核、超时回收、状态验证闭环。

> **机制事实源**：看板底层怎么运转（数据在哪、9 态状态机、dispatcher 选卡条件、锁与 TTL、
> 熔断与回收、排障直查 SQL）以 `references/kanban机制说明书.md` 为准（含文末"勘误与补录"节，
> 为 2026-10-13 对本机 Hermes 源码逐条核实后的修正）。本文件只写**操作规程**，不复述机制。

## 铁律（每条都有机制依据，违反即事故）

1. **每个 `hermes kanban` 子命令必须显式带 `--board <板>`**。`current` 指针是全局单值，
   不带板名的命令会静默打到别的板上（claim 尤其致命：日志写"claimed → running"，目标板纹丝不动，
   该卡还会被自动派单再派一次 → 双 worker 同写一份代码）。
2. **assignee 是路由键，不是负责人备注**。本 kit 的外部执行者模式下，任务一律派给
   **非真实 profile 名**的 lane（如 `claude-code-lane`）——内置 dispatcher 的 profile 门会跳过
   这类卡，这是防"Hermes 自己抢单跑代码"的机制手段（说明书 §13.2 手段①，本机实测有效：
   `hermes kanban assignees` 里 `claude-code-lane` 显示 `ON DISK: no`）。
   **禁止把卡 assign 给 `default` 或任何真实 profile 名**，除非明确要走 Hermes 内置 worker。
   配套前提：本机 `kanban.default_assignee` 必须为空（否则无 assignee 的 ready 卡会被网关
   自动兜底派出，见说明书勘误 E4）。
3. **claim 后必须复核状态**。claim 会静默失败（错板、状态不满足、锁被占），失败时输出可能被
   丢弃；复核 = `hermes kanban --board <板> show <卡号>` 确认 `status=running` 且 `claim_lock` 归属正确。
4. **block 必须带 `--kind`**。依赖等待用 `--kind dependency`（落 `todo`，不进人工池）；
   等人工给信息用 `--kind needs_input`；临时故障用 `--kind transient`。无类型 block 会污染
   blocked 扫描池（说明书 §五）。
5. **`unlink` 前必须核验父卡产出已落盘**（git 实据，不看自报）。unlink 的瞬间子卡满足依赖条件，
   下一轮派单即认领——"双派双写"事故的经典触发路径（说明书 §6.3）。

## 核心能力

### 0. 建卡派发（S4 唯一入口 · 硬闸门）

**任何任务在写 TASK.md / 建 worktree / 派发编码代理之前，必须先 `hermes kanban --board <板> create` 上板。**
TASK.md 里的"当前状态"字段仅是缓存，看板才是唯一事实源；只写 TASK.md 不上板 = 漏板失职，
且 watchdog 巡检只扫**已在板上**的卡，从未上板的卡不会有任何机制兜底。

标准顺序（每张卡，命令照抄勿即兴发挥；`--board` 与 lane assignee 为铁律 1/2 要求）：

```bash
# ① 建卡 —— 拿到 t_xxxxxxxx 才算这张卡存在
hermes kanban --board <板> create "T-NNN: <动词+对象+结果>" \
  --body "TASK.md: <绝对路径> | 来源: <PRD/DD#章节> | files_scope: <边界>" \
  --assignee <lane名> \
  --workspace worktree --branch claude/<slug> \
  --idempotency-key T-NNN --initial-status running --json
#    ↑ 路由键（非真实 profile 名，防网关抢单）  ↑ 防重复建卡   ↑ 手动 claude -p 派发时用 running 占位，
#                                                              否则 ready 卡会被 dispatcher 认领后双跑

# ② 自验卡片确实在板上（输出必须含 ① 返回的 id，否则视为建卡失败）
hermes kanban --board <板> list --json | python -c "import sys,json;[print(t['id'],t['status'],t['title'][:40]) for t in json.load(sys.stdin) if t['id']=='<①返回的id>']"

# ③ 写 TASK.md 落盘 → 派发（dispatcher 自动认领，或手动 claude -p）

# ④ 编码代理收口后立即回板（完成验证闭环见 §4）
hermes kanban --board <板> complete <id> --summary "<验收结论>" --metadata '{"commit":"<hash>","changed_files":[...]}'
```

约束：
- 标题前缀 = 任务卡 ID（`T-003: ...`），看板 ↔ 任务卡双向可回溯
- `--idempotency-key` 一律填任务卡 ID，补账/重跑天然去重
- **会话收尾自查**：diff `.hermes/tasks/` 新增 TASK.md 与本会话建卡 id 清单，
  发现漏板的当场补建并回补状态，禁止留给下次
- 已合并的漏板历史任务补账：`create --initial-status running` 后立刻 `complete --summary "<commit+验收结论>"`；
  未验收完的建卡后 `block <id> --kind needs_input "<待办原因>"`，不许默默留在 ready

### 1. 悬空卡处置（Dangling-Ready）

```bash
# 查无 assignee 的 ready 卡（必须带板名）
hermes kanban --board <板> list --status ready --json
```

**处置策略**：
- 无 assignee 的 ready 卡 = 建卡遗漏路由键 → **补派 lane 名**（`assign <卡号> <lane名>`，
  lane 名须符合铁律 2），同时通知用户，不做静默兜底
- 有 lane assignee 但长期 ready → `tail <卡号>` 查事件流：`skipped_nonspawnable` = 外部执行者
  未取单（正常，等哨兵）；无事件 = 检查网关是否在跑（dispatcher 在网关里，网关停=不派单）
- ready + 反复 claim 报 `lock=<主机>:<PID>` = 孤儿锁 → 见「超时回收」第 3 步

### 2. 心跳与巡检

- lane worker（agent-bridge 后台任务）由哨兵脚本轮询 `~/.workbuddy/agent-bridge/tasks/*/status.json`
  判活：PID 死 → `BRIDGE_LANE_DEAD`；日志超阈值无更新 → `BRIDGE_LANE_STALE`
- Hermes 内置 worker 的心跳走 `hermes kanban --board <板> heartbeat <卡号>`（worker 侧发）
- 每 15 分钟 cron 巡检（见兜底 watchdog）；`running` 卡超时判据 = claim TTL 15 分钟过期后仍未
  reclaim，或 `dispatch_stale_timeout_seconds`/`max_runtime_seconds` 命中

### 3. 超时与孤儿回收

| 情形 | 判别 | 处置 |
|------|------|------|
| lane 进程已死（卡仍 running） | status.json 的 PID 不存活 | `reclaim <卡号>` 释放认领 → 重新派发 |
| 孤儿 claim_lock（卡 ready 但 claim 报 lock=） | **裸跑一次 claim（不要重定向输出）**看真实报错 | 确认锁主进程确已死亡 → `reclaim <卡号>`；**不要用 `unblock` 治孤儿锁**（卡不是 blocked 态，无效动作） |
| 卡超时（running 过久） | `show` 对比 `started_at`；或 `diagnostics` 列出活跃诊断项 | 可恢复 → `reclaim` 后重派；不可恢复 → `block --kind needs_input "需人工介入：XXX"` |
| 同因 block→unblock→再 block 循环 ≥2 次 | 卡自己掉进 `triage`（机制使然，非 bug） | 人工分诊：`specify` 细化或改派后 `promote`；看 `block_recurrences` 与 `block_loop_detected` 事件 |

**恢复路径命令族**（不存在 `reopen`，历史文档误用已清理）：
`promote`（todo/blocked→ready 手动提卡）、`unblock`（blocked/scheduled→ready，父卡未完成则回 todo）、
`reclaim`（释放过期/孤儿认领）。

### 4. 完成验证闭环

外部执行者完成任务后，必须验证产出再标记 complete：

```
1. git diff --stat HEAD          # 确认有变更（实据，不看自报）
2. 项目编译命令                    # 编译通过
3. 核对 changed_files            # 与 TASK.md 一致
4. hermes kanban --board <板> complete <卡号> --summary "..." --metadata '{"changed_files":[...]}'
```

**零产出判定**：`git status --short` 和 `git diff --stat HEAD` 均为空 → 委派失败 → STOP 转人工处置
（先 `block --kind needs_input`，不自动重派——`consecutive_failures` 达 2 次即熔断，熔断后不再自动重派）。

## 命令速查（全集见 `hermes kanban --help`）

| 操作 | 命令 |
|------|------|
| **建卡（S4 第一步，见 §0）** | `hermes kanban --board <板> create "T-NNN: <标题>" --body "..." --assignee <lane名> --workspace worktree --branch claude/<slug> --idempotency-key T-NNN --initial-status running --json` |
| 列卡（按态过滤） | `hermes kanban --board <板> list --status <9态之一> --json` |
| 查看未分配任务 | `hermes kanban --board <板> list --json` 过滤 ready+null assignee（处置见 §1） |
| 任务详情+评论+事件 | `hermes kanban --board <板> show <卡号>` |
| 补派/改派 | `hermes kanban --board <板> assign <卡号> <lane名>`（真实 profile 名见铁律 2） |
| 原子认领 | `hermes kanban --board <板> claim <卡号> --ttl 7200`（**认领后复核**） |
| 释放孤儿/过期认领 | `hermes kanban --board <板> reclaim <卡号>` |
| 标记完成 | `hermes kanban --board <板> complete <卡号> --summary "..."` |
| 类型化阻塞 | `hermes kanban --board <板> block <卡号> --kind needs_input "reason"` |
| 解阻/提卡 | `hermes kanban --board <板> unblock|promote <卡号>` |
| 依赖边 | `hermes kanban --board <板> link <子卡> <父卡>`（unlink 见铁律 5） |
| 历次派单记录 | `hermes kanban --board <板> runs <卡号>`（**task_id 必填**，无 `--active`） |
| 事件流 | `hermes kanban --board <板> tail <卡号>` / `watch`（全板） |
| 活跃诊断 | `hermes kanban --board <板> diagnostics` |
| 板概况 | `hermes kanban --board <板> stats` |
| profile 门实况 | `hermes kanban assignees`（ON DISK 列=是否真实 profile） |

## 状态口径对照（文档词 → 看板 9 态真名）

kit 文档与聊天里习惯用的进度词，落库真名如下（写卡/查卡/扫描一律用真名）：

| 文档口径词 | 看板真名 | 备注 |
|-----------|---------|------|
| TODO / 待办 | `todo` 或 `ready` | 等父卡=todo；可派=ready |
| IN_PROGRESS | `running` | |
| IN_REVIEW | `review` | 实现完成等审查，**不是阻塞**，且默认会被自动派单 |
| BLOCKED | `blocked` | 只放需要人工处理的卡 |
| DONE | `done` → 归档 `archived` | done≠archived，S7 才 archive |

## 外部哨兵模式自承担清单（内置 dispatcher 白送、我们不用的部分）

本 kit 用外部执行者（Claude Code 等）跑卡，等于主动绕开内置 dispatcher（防双写）。
绕开后以下三件事**必须自己保证**（说明书 §13.3）：

1. **promote**：父卡 done 后把子卡从 todo 提到 ready —— 由 cron 哨兵唤醒的 agent 按本技能处置
2. **reclaim**：过期/孤儿认领释放 —— 同上，判据见「超时与孤儿回收」表
3. **并发与熔断计数**：熔断计数在 DB 的 `consecutive_failures`（成功才清零，默认 2 次跳闸）；
   哨兵自身的冷却计数**必须落盘**（cron 每轮新进程，内存计数会清零 → 同卡无限重派）

## 在工作流中的位置与配合

本技能是**执行层的任务生命周期管理者**，不负责拆需求、不改码。

- **上游**：`project-workflow` 在 S4 阶段拆出任务卡后，交给本技能建卡派发（顺序固定为 **§0 建卡上板 → 写 TASK.md → 认领**，禁止先写 TASK.md 后补卡；`create` 带 lane assignee，**建卡后立即核对 assignee**，防被内置 dispatcher 抢单或悬空不派）
- **下游**：编码代理（Claude Code/Codex）产出后，本技能做**完成验证闭环**（git diff 非空 + 编译通过 + changed_files 核对），通过才标 `done`
- **旁路**：`codegraph-review` 在编码代理改码**之前**被调用评估波及面，评估报告作为任务卡附件
- **兜底**：cron 任务 `kanban-board-watchdog` 每 15 分钟跑 `scripts/kanban-watchdog.py`（monitor 模式，指纹不变不唤醒 agent、零 token；变化才唤醒本技能规则处置：悬空卡补派 lane、超时卡回收/阻塞、done 卡验收闭环后归档、lane 断头判死因、孤儿锁 reclaim）。指纹信号：CLAIM_PENDING / IN_PROGRESS_TIMEOUT / DONE_UNVERIFIED / BLOCKED / BRIDGE_LANE_DEAD / BRIDGE_LANE_STALE / DIAG_ACTIVE。部署见 kit DEPLOY.md「三、部署步骤」第 4 步（看板巡检 watchdog）

**调用时机**：看板出现 ready/blocked/超时任务，或 S4 需要建卡派发时，加载本技能。

## 参考资料

- `references/kanban机制说明书.md` — 机制唯一事实源（13 章 + 附录，含 2026-10-13 本机源码核实的
  "勘误与补录"节 E1–E5：附录 A 命令不全、§8.4 静默不派已改为记 `skipped_nonspawnable` 事件、
  配置键全表缺漏、`default_assignee` 兜底派出行为、`list --json` 无 claim_lock 字段）
