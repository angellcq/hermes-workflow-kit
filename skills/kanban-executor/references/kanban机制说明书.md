---
title: Hermes 看板机制说明书（自包含）
tags: [hermes, kanban, mechanism, dispatcher, sqlite, multi-agent, reference]
created: 2026-09-22
version: 1.0
---

# Hermes 看板机制说明书

> **本文与《Hermes 自动化工作流 · 迁移手册》的分工**
> 迁移手册回答「**怎么用**」（装什么、敲什么命令、踩过哪些坑）。
> 本文回答「**它怎么运转**」（数据在哪、状态怎么流转、谁在什么时候自动动手）。
> 两者合起来才是完整文档；只有前者时，出问题无法判断是机制使然还是自己配错。
>
> **本文零项目信息、零绝对路径。** `<hermes家目录>`、`<板名>`、`<profile名>`、`<仓库路径>` 均为占位符，
> 按目标机实际值替换。所有指向位置的路径都从 `<hermes家目录>` 起算，换机不需要改正文。
>
> **核实方式**：本文每条机制均来自阅读 Hermes 源码（`hermes_cli/kanban*.py`、
> `gateway/kanban_watchers*.py`）与直查看板 SQLite，标注为 `[源码]` 或 `[实测]`；
> 凡属推断标注 `[推断]`。版本随 Hermes 迭代可能漂移，**核对入口在第 10 章的直查 SQL**。

**目录**

| 章 | 内容 |
|---|---|
| [一](#一先建立正确心智模型) | 先建立正确心智模型（看板是什么 / 不是什么） |
| [二](#二数据落在哪) | 数据落在哪（目录、DB、八张表） |
| [三](#三schema) | schema（tasks 全列 + 附表） |
| [四](#四状态机全集) | **状态机全集（9 个状态，不是 4 个）** |
| [五](#五block-的类型化路由) | block 的类型化路由（`dependency` 不进 blocked） |
| [六](#六依赖链与-ready-重算) | 依赖链与 ready 重算（谁把卡从 todo 提上来） |
| [七](#七claim锁ttl) | claim、锁、TTL（含静默失败与孤儿锁） |
| [八](#八dispatcher网关内嵌) | **dispatcher**（网关内嵌的自动派单器） |
| [九](#九并发熔断与回收) | 并发、熔断、回收 |
| [十](#十排障直查看板-db) | 排障：直查看板 DB |
| [十一](#十一配置键全表) | 配置键全表 |
| [十二](#十二判断我的板安不安全) | 判断「我的板安不安全」 |
| [十三](#十三与外部派单哨兵模式的分工) | 与「外部派单哨兵」模式的分工 |
| [附录](#附录-a命令速查) | 命令速查 / 自查清单 |

---

## 一、先建立正确心智模型

| 看板**是** | 看板**不是** |
|---|---|
| 一个**跨 profile 共享**的持久化任务库（SQLite 文件） | 内存里的界面状态（重启不丢，DB 是唯一真相） |
| **状态真相**：任何界面显示的都不如 DB 里的 `status` 权威 | 只是一个"待办清单 UI" |
| 一个**有主动行为**的系统：网关内嵌 dispatcher 会自己认领并启动 worker | 一个被动容器（这点最反直觉，见第八章） |
| 依赖图的载体（`task_links` 表就是一条边） | 只能表达"先后"，不能表达"归属" |

**三条最容易搞错的前提**：

1. **一个板 = 一个 SQLite 文件**，不是"一张表里的一个字段"。跨板查询必须分别打开各板 DB。
2. **`assignee` 不是"负责人备注"，是路由键** —— 它的值是 **Hermes profile 名**，dispatcher 靠它决定启动哪个 profile 的 worker。名字写错 = 卡永远不被派（且不报错）。
3. **看板自带自动派单，不需要你写调度器** —— 但如果你用的是「外部 agent 执行者」模式（如外部编码 CLI），你会主动**绕开**它，于是必须自己保证派单。绕开的方法与判断见第十三章。

---

## 二、数据落在哪

### 2.1 目录布局

```
<hermes家目录>/kanban/
├── current                     ← 「当前板」指针（纯文本单行，内容=板名）
├── .dispatcher.lock            ← dispatcher 单例锁（防两个网关同时派单）
├── attachments/<卡号>/         ← 板上附件的顶层目录（部分版本）
└── boards/<板名>/
    ├── board.json              ← 板元数据
    ├── kanban.db               ← ★ 板的全部数据（SQLite）
    ├── kanban.db-wal           ← WAL 日志（并发写靠它）
    └── kanban.db-shm           ← WAL 共享内存索引
```

`[实测]` 板名以目录名形式落盘；`_archived` 是一个**特殊板名目录**，用于归档板本身，
不是"板里的归档卡"（卡级归档是 `status='archived'`，同一个 DB 里）。

### 2.2 `current` 指针为什么重要

`hermes kanban` 的子命令**不带 `--board`** 时读这个文件决定操作哪个板。
它是一个**全局单值**，会被你在**任何**板上的操作改写。

后果：在 A 项目派单，会把全局指针切到 A 的板；此后你在 B 项目**不带 `--board`** 的命令
全部静默作用到 A 的板上（`claim` 尤其致命：日志写"claimed → running"，B 的板却纹丝不动）。

**规矩：任何脚本里的每个 `kanban` 子命令都必须显式带 `--board`，板名作参数传入。**

### 2.3 多板共存

一个 Hermes 家目录下可以有任意多个板，彼此独立（各自一个 DB）。
`[实测]` 典型规模：单板几百张卡、单库几 MB 量级，SQLite 完全够用。

> **板 vs 项目（project）是两套独立体系**，只是名字常常撞巧。
> 建项目不会建板，建板不会绑项目；绑定接口对不存在的板**静默 return**（不报错）。
> 绑定的副作用见第十三章（会改变任务的工作区形态）。本说明书按「不绑」描述。

---

## 三、schema

`[源码]` 建表语句在 `hermes_cli/kanban_db.py`。**八张表**：

| 表 | 作用 |
|---|---|
| `tasks` | 卡本体（39 列，见下） |
| `task_links` | 依赖边：`parent_id` + `child_id`（复合主键） |
| `task_comments` | 评论（人工/协调者留言，含交付说明） |
| `task_events` | **事件流**（状态变更、派单、完成…，`kind` + `payload` JSON） |
| `task_runs` | **每次派单一行**（profile / worker_pid / status / claim_lock） |
| `task_attachments` | 附件（元数据 + 存储路径） |
| `kanban_notify_subs` | 通知订阅（哪个平台/会话要收这张卡的事件） |
| `sqlite_sequence` | SQLite 自增内部表（忽略） |

### 3.1 `tasks` 关键列（排障只需要认识这些）

| 列 | 含义 |
|---|---|
| `id` | 卡号（`t_` + 8 位十六进制） |
| `title` / `body` / `assignee` / `priority` | 卡面与路由键；`priority` 降序参与排序 |
| `status` | ★ 状态机当前态（第九章… 见第四章） |
| `created_at` / `started_at` / `completed_at` | 时间戳。**注意格式**：整数 epoch 秒；历史上出现过 ISO 文本混入导致排序崩溃 |
| `claim_lock` / `claim_expires` | 认领锁与租约（第七章） |
| `worker_pid` / `worker_started_at` | 执行进程及其**启动指纹**（防 PID 回收误判） |
| `consecutive_failures` | 连续失败计数，成功才重置；熔断判据（第九章） |
| `last_failure_error` | 最近一次失败的错误摘要 |
| `current_run_id` | 指向 `task_runs` 当前活跃行 |
| `max_runtime_seconds` / `last_heartbeat_at` | 超时与心跳（第九章） |
| `block_kind` / `block_recurrences` | 类型化阻塞原因与同因循环计数（第五章） |
| `session_id` | 从哪个 agent 会话建卡（便于回溯） |
| `model_override` / `provider_override` / `reasoning_effort` | 逐卡模型覆写，dispatcher 派单时透传给 worker |
| `skills` | 强制加载的技能（JSON 数组），经 `--skills` 传给 worker |

`[实测]` 该表**还有** `workspace_kind`/`workspace_path`/`branch_name`/`project_id`（工作区形态）、
`tenant`、`idempotency_key`、`max_retries`、`goal_mode`/`goal_max_turns`（Ralph 式目标循环）、
`workflow_template_id`/`current_step_key`（v2 工作流预留，现行 dispatcher 不据此路由）。

### 3.2 直查时的两个硬提醒

1. **先取 schema**：`PRAGMA table_info(tasks)`。这套字段名与别处同名表**不一样**
   （本表**没有** `depends_on`、**没有** `updated_at`）。凭猜字段名写 SQL 会白跑一轮。
2. **WAL 并发**：dispatcher 与本机并发操作同一 DB。拿到 `database is locked` 是正常竞争——
   sleep 5–10 秒重试，或先 `PRAGMA wal_checkpoint(TRUNCATE)` 缩短窗口期。
   **绝不为了"抢进度"改成 `journal_mode=OFF`**：破坏 WAL 会让看板 UI 和 dispatcher 一起崩。

---

## 四、状态机全集

`[源码]` `hermes_cli/kanban_db.py`：

```python
VALID_STATUSES = {"triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done", "archived"}
```

**九个状态，不是四个。** 只记 `ready/running/done/blocked` 会在遇到
`triage`/`scheduled`/`review`/`archived` 时误判为"卡丢了"。

### 4.1 各状态语义与进入方式

| 状态 | 含义 | 怎么进入 | 谁能离开它 |
|---|---|---|---|
| `triage` | 待人工分诊（**新建卡的常见初始态之一**；也是**死循环兜底态**） | 建卡时未指定、或从 `blocked` 循环超限降级而来 | 人工 `decompose`/`specify`/`promote`，或 dispatcher 的 auto-decompose |
| `todo` | 等父卡完成（**依赖等待专用态**） | 建卡带父卡时；`block --kind dependency`；`unblock` 时父卡未完成 | **`recompute_ready`** 自动提升（第六章） |
| `scheduled` | 等时间（不是等人） | `hermes kanban schedule` | 到点或被 `unblock` |
| `ready` | 可派：只等 dispatcher 认领 | 建卡默认；`promote`；`unblock`；父卡全完成时自动 promote | dispatcher `claim` → `running` |
| `running` | 已被认领并启动 worker | `claim`（原子） | worker 结束（done/blocked/review）、或回收（第九章） |
| `blocked` | 卡住了，**等人**处理 | `block`（非 dependency 类）；派单失败达阈值 | 人工 `unblock` → ready/todo |
| `review` | 实现完成、**等审查**（不是阻塞！） | `request-review` | 审查通过 → done；`request-changes` → 回实现者 |
| `done` | 终态 | `complete` | `archive` |
| `archived` | 终态（折叠出视图） | `archive` | 一般不再流转 |

### 4.2 三个最容易漏的态

- **`scheduled` ≠ `blocked`**：前者等**时间**，后者等**人**。把等时间的卡放 `blocked`
  会让它出现在"需要人工处理"的池子里，长期污染你的待办视图。
- **`review` ≠ `blocked`**：`request-review` 的语义是"实现已完成，请审查"，
  它是**正常流转**而非阻塞。且 review 车道**默认也会被自动派单**（见第八章）。
- **`triage` 是兜底态**：同因 `block → unblock → re-block` 循环达 **2 次**
  （`BLOCK_RECURRENCE_LIMIT = 2` `[源码]`）后，卡被路由到 `triage` 并记事件
  `block_loop_detected` —— 这是**设计意图**：反复卡在同一原因说明需要**人**来看，
  不该继续自动重试。看到 `triage` 卡不是 bug，是机制在向你求救。

### 4.3 主流程图

```
                    ┌──────────┐
   建卡（带父卡）──▶ │   todo   │ ──父卡全 done/archived──┐
                    └──────────┘    （recompute_ready）  │
                    ┌──────────┐                        ▼
   建卡（无父卡）──▶ │  ready   │ ──── claim ────▶ ┌──────────┐
                    └──────────┘                  │ running  │
                         ▲                        └────┬─────┘
                         │ unblock                     │
                    ┌──────────┐     ┌──────────┐      ├──▶ done ──▶ archived
                    │ blocked  │◀────│  失败/   │◀─────┤
                    └────┬─────┘     │  阻塞    │      └──▶ review ──▶ done
                         │           └──────────┘                │
        同因循环≥2次     ▼                                    request-changes
                    ┌──────────┐                                  │
                    │  triage  │◀── 人工分诊 ◀── auto-decompose     ▼
                    └──────────┘                            ready / todo
```

---

## 五、block 的类型化路由

`[源码]` `VALID_BLOCK_KINDS = {"dependency", "needs_input", "capability", "transient"}`，
路由逻辑在 `_route_block()`。

| `block_kind` | 落到哪个状态 | 为什么 |
|---|---|---|
| `dependency` | **`todo`**（不进 `blocked`！） | 让它在 `todo` 等 `recompute_ready`；这样任何"扫描需要人工处理的卡"的自动化**永远不会**把依赖等待当成"该解锁的卡" |
| `needs_input` | `blocked` | 等人给信息 |
| `capability` | `blocked` | 等人/工具具备能力 |
| `transient` | `blocked` | 临时性问题 |
| `NULL`（旧式无类型） | `blocked` | 兼容老数据 |

**关键设计**：`dependency` **故意不落在 `blocked`**。所以——

> 如果你的自动化在扫描 `blocked` 卡并批量解锁，**依赖等待的卡根本不在那个池子里**。
> 反过来，如果你在 `blocked` 里看到一张"其实只是等父卡"的卡，那是**旧数据或无类型 block**，
> 不是正常形态。

若调用方声明 `dependency` 但**实际没有未完成的父卡**，源码会把它**改判为 `needs_input`**
再落 `blocked`（因为确实需要人）。`[源码]`

---

## 六、依赖链与 ready 重算

### 6.1 依赖边

```bash
hermes kanban --board <板> link   <子卡> <父卡>   # 加边：父卡完成前子卡不派
hermes kanban --board <板> unlink <子卡> <父卡>   # 去边（慎用，见下）
```

`[源码]` 存在 `task_links(parent_id, child_id)`，**一条边一行**，无其它字段。
"同文件域必须串行"这类约束就是**用依赖边表达的**——不要靠"我记得"。

### 6.2 `recompute_ready` —— 谁把卡从 `todo` 提上来

`[源码]` `kanban_db.recompute_ready()`：

> Promote `todo`/`blocked` tasks whose parents are all done/archived; returns the count.

要点：

- **触发者**：dispatcher 每轮（`hermes kanban dispatch` 一轮 = *reclaim stale → promote ready → spawn workers*，
  见第八章）。也就是说**你不需要手动 promote**，父卡一 `done`，子卡会在下一轮自动变 `ready`。
- **`blocked` 会被跳过**的条件：卡是**显式** `kanban_block`（sticky，worker 自己请求阻塞的
  必须人工 `unblock`），或 `consecutive_failures` 已达熔断阈值（否则熔断器永远没机会跳闸）。
- **它自己开 IMMEDIATE 事务** → 调用点必须在**任何写事务之外**（自己写脚本时注意）。

### 6.3 `unlink` 的副作用（为什么"慎用"）

解除依赖会让子卡**立刻**满足"父卡全完成"的条件，于是它可能在**同一瞬间变 `ready`**。
如果此时该板有自动派单在跑，卡会被**立即派出去**——而父卡其实还没完成。

**这是"双派双写"事故的经典触发路径。** 正确姿势：

1. 先确认父卡产出**真的落盘**（git 核验，不看自报）；
2. 再 `unlink`；
3. 且清楚知道`unlink` 之后**下一轮派单就会认领它**。

---

## 七、claim、锁、TTL

### 7.1 claim 是什么

`claim` = **原子地把卡从 `ready` 变 `running`**，并写下 `claim_lock` + `claim_expires`
（默认 TTL **15 分钟**：`DEFAULT_CLAIM_TTL_SECONDS = 15 * 60` `[源码]`）。

`claim_lock` 的典型值是 `主机名:进程号` `[实测]`——**它标识的是"谁认领的"，用于排查**。

### 7.2 claim 会**静默失败**（最重要的坑）

不带 `--board` 打到错板、卡状态不满足、锁被占……**失败时输出可能被丢弃**，
表现为"命令跑完了，什么都没发生"。

后果：「worker 在跑，但看板显示 `todo`」→ 而 `todo`/`ready` 的卡会被自动派单**再派一次**
→ 两个 worker 改同一份代码。

**规矩：claim 后必须复核状态。**

### 7.3 孤儿锁（claim_lock 没释放）

派单过程中 worker 崩溃或被强杀（断电、误杀），`claim_lock` 可能**留在表里**。
此后每次 claim 都被顶回，报形如 `cannot claim <id>: status=ready lock=<主机名>:<PID>`。

**危害**：自动派单器会反复重试直到**熔断**，于是这张卡**永久不再被派**——
而看板上它仍是 `ready`、依赖也满足，表面上一切正常。

**判别**：裸露跑一次 claim（**不要重定向输出**）看真实报错是不是 `lock=...`。

```bash
# 不带 >/dev/null —— 要看真报错
hermes kanban --board <板> claim <卡号> --ttl 7200
```

**处置**：确认那个 PID 的进程**确已死亡**后，`reclaim` 释放锁：

```bash
hermes kanban --board <板> reclaim <卡号>
```

> 若你另外还有自己的派单状态文件（记录冷却/熔断计数），**同时**要把该卡的计数清掉，
> 否则它仍会被跳过。清计数要在**没有派单轮次在跑**的窗口里做，否则会被对方重写覆盖。

**不要用 `unblock` 治孤儿锁**：卡本来就是 `ready` 不是 `blocked`，`unblock` 是无效动作。

### 7.4 手动派单前的防双开

前台跑派单命令**超时（exit 124）不代表进程没起来**——外部 agent 往往已经在跑。
**盲目补派 = 同卡两个 worker 并发写同一批文件。**

补派前必须先**验尸**：按卡号 / agent 名过滤进程列表，确认没有存活进程。
且派单一律放到后台执行。

---

## 八、dispatcher（网关内嵌）

### 8.1 它是什么

`[源码]` `gateway/kanban_watchers*.py`：**dispatcher 内嵌在 Hermes 网关里**，是一个
按固定间隔跑的后台循环。`hermes kanban daemon` 已**废弃**（帮助文本明写
"dispatcher now runs in the gateway. Use `hermes gateway start`"）。

| 项 | 值 | 来源 |
|---|---|---|
| 所在 | 网关进程内 | `[源码]` |
| 间隔 | `kanban.dispatch_interval_seconds`，默认 **60 秒**，下限 1 秒 | `[源码]` |
| 单例 | `<hermes家目录>/kanban/.dispatcher.lock`，抢不到锁就不跑 | `[源码]` |
| 通知 watcher | 独立循环，间隔默认 **5 秒**（推事件给订阅方） | `[源码]` |

> **所以"看板卡没人派"的第一件事是看网关在不在**：网关停了，dispatcher 就停了。
> 这与"外部派单哨兵"模式的关键差别也在这里（第十三章）。

### 8.2 一轮做三件事

`[源码]` `dispatch` 子命令的自述即一轮的定义：

> One dispatcher pass: **reclaim stale, promote ready, spawn workers**

1. **reclaim stale** —— 回收过期/死亡的认领（第九章）
2. **promote ready** —— `recompute_ready`，把依赖已满足的卡从 `todo` 提上来（第六章）
3. **spawn workers** —— 认领并启动 worker

外加（不同版本齐备度不一）`auto_decompose`：把 `triage` 卡**自动拆解**成 ready 工作图，
每轮上限可配（`[源码]` `auto_decompose_tick`）。**这是 `triage` 卡会自己消失的另一原因。**

### 8.3 选卡条件（精确）

`[源码]` 车道查询 `_lane_rows()`：

```sql
SELECT id, assignee FROM tasks
WHERE status = '<lane>' AND claim_lock IS NULL
ORDER BY priority DESC, created_at ASC
```

即：**状态对 + 未被认领 + 按 priority 降序、再按创建时间升序**。

`"是否有可派卡"` 判据 `_has_spawnable()`：

```sql
SELECT DISTINCT assignee FROM tasks
WHERE status = ? AND assignee IS NOT NULL AND claim_lock IS NULL
```
→ 再逐个**验证 assignee 是否是真存在的 profile**。

两条"车道"：`ready`（普通任务）和 `review`（审查任务，由 `kanban.review_dispatch`
控制，**默认开**，因为 Hermes 自带 `sdlc-review` profile）。

### 8.4 profile 门（为什么"名字写错就永远不派"）

派单前会检查 `assignee` 对应的 **profile 是否存在**：

- 存在 → 用该 profile 启动 worker
- **不存在 → 跳过这张卡**（`[源码]` 注释：让健康遥测能区分"卡住了"和"正确地空闲"）

**没有报错、没有事件，就是静默不派。** 卡永远停在 `ready`。

> **排查口诀**：卡在 `ready` 一直没人派 → 先查 `assignee` 是不是真 profile 名。

另外有两个收窄门：

- `kanban.dispatch_profiles` —— **白名单**，只有名单内 profile 的卡会被这个家目录派单
  （多实例共享一个家目录时用来划界）。
- `kanban.default_assignee` —— 给**没有 assignee** 的 `ready` 卡兜底指派。
  未配置时这类卡被**无限期跳过**（`[源码]` 注释明说）。

### 8.5 派单前的守卫（`check_respawn_guard`）

`[源码]` 每张候选卡在 claim 之前过一道守卫，返回原因就不派：

| 守卫原因 | 含义 |
|---|---|
| `infrastructure_cooldown` | 上次是"宿主机拒绝启动"（非卡的错），冷却中；**不计入失败** |
| `rate_limit_cooldown` | 上次是限流（配额/鉴权），冷却中（默认 **300 秒**）；**不计入失败** |
| `blocker_auth` | 命中配额/鉴权特征（熔断器最终仍会跳闸） |
| `recent_success` | **近期刚成功完成**过（除非之后又有明确的重新入队事件） |
| `active_pr` | 近期评论里有 PR 链接（再派可能产生**重复 PR**；除非之后有移交事件） |

说明两点：

- `recent_success` / `active_pr` **只在 `ready` 车道生效**；`review` 车道不用它们
  （因为它们恰恰是"移交审查"的**输入**）。
- **过期的/死的认领锁不是守卫原因** —— 那是 reclaim 阶段的职责（第七章）。

### 8.6 派单顺序与容量预留

`[源码]` 一轮内的顺序：先 review 车道、再把剩余容量分给 ready 车道
（`_any_spawnable_review` 会先"预留"容量，避免 review 行把 ready 预算挤成 0）。

---

## 九、并发、熔断与回收

### 9.1 并发上限（三层）

| 层 | 配置键 | 说明 |
|---|---|---|
| 全局 | `kanban.max_in_progress` | 未配置时用**内存推导**的默认上限 `[源码]` |
| 每 profile | `kanban.max_in_progress_per_profile` | 防单角色并发改同一批文件 |
| 每轮启动数 | `kanban.max_spawn` | 单轮最多派生几个 |

`[源码]` 内存守卫的两道保险：**按每 worker 512 MB 估算**推导默认上限
（`MEMORY_GUARD_MB_PER_WORKER = 512`），加一个**运行期内存压力守卫**
（静态上限看不到同机其它租户）。两者**都是 fail-open**：读不到内存就不设限。

> **为什么值得关心**：源码注释记录过一次真实事故——无上限的板把一台
> **1 GiB 内存**的宿主 OOM 掉了。宿主内存小就必须配 `max_in_progress`。

### 9.2 熔断（`consecutive_failures`）

`[源码]` `DEFAULT_FAILURE_LIMIT = 2`：

- 每次 spawn 失败/超时/崩溃 → `consecutive_failures += 1`
- **只有成功完成才清零**
- 达到阈值（`max_retries` > `failure_limit` > 默认值 的优先级）→ 熔断，停止重派，交人工

配合 `last_failure_error`（错误摘要）判读。

### 9.3 回收机制族（`[源码]` 函数名即语义）

| 机制 | 作用 |
|---|---|
| `detect_stale_running` | 找超时/心跳超期的 `running` 卡 |
| `reconcile_orphaned_running` | 对账"看板说 running 但进程没了"的孤儿（`kanban.reconcile_orphans` 默认 **true**） |
| `detect_crashed_workers` | 检出崩溃的 worker 并记失败 |
| `enforce_max_runtime` | 按 `max_runtime_seconds` 强杀超时 worker |
| `heartbeat_worker` | worker 心跳 |
| `reap_worker_zombies` / `reap_terminal_workers` | 收尸（终态卡上仍活着的 worker 进程也要清） |
| `_pid_recycled` / `_process_fingerprint` | **PID 回收防护**：存活判定与杀进程都要求 `pid` **和**启动指纹同时吻合，重启后被复用的 PID 不会被误认为"我们的 worker" |
| 日志轮转 | worker 日志 2 MiB × 1 备份（`DEFAULT_LOG_ROTATE_BYTES` / `_BACKUP_COUNT`） |

> **`worker_pid` 与真实进程会脱钩**：收尾只写状态、不清 `worker_pid`。
> 所以"卡在 running 但进程全无"和"进程活着但卡已 done"**都可能出现**。
> 判断真实情况永远以「进程列表 + 事件流 + 提交证据」三者交叉，不看单一字段。

---

## 十、排障：直查看板 DB

### 10.1 标准四步

1. **确认板是否存在**：`<hermes家目录>/kanban/boards/<板名>/kanban.db` 在不在。
   不在 = 板名写错，不是"卡丢了"。
2. **取 schema**：`PRAGMA table_info(tasks)`（字段名与别处同名表不同，见 3.2）。
3. **查状态**：
   ```sql
   SELECT id, status, assignee, priority, consecutive_failures, claim_lock,
          datetime(created_at,'unixepoch','localtime') AS created
   FROM tasks ORDER BY created_at DESC LIMIT 50;
   ```
4. **看事件流**（比状态更能说明"发生过什么"）：
   ```sql
   SELECT datetime(created_at,'unixepoch','localtime') AS t, kind, payload
   FROM task_events WHERE task_id = '<卡号>' ORDER BY id;
   ```

### 10.2 别名对照（避免假阴性）

| 想查 | 别只查 | 应查 |
|---|---|---|
| 卡的依赖 | `tasks.depends_on`（**不存在**） | `SELECT parent_id FROM task_links WHERE child_id='<卡号>'` |
| 卡是否被阻塞的原因 | 只看 `status` | `status` + `block_kind` + `block_recurrences` |
| "任务丢了" | `hermes kanban list \| grep <卡号>`（姿势易假阴性） | 直查 DB 的 `tasks` 表 |
| 谁在跑 | `tasks.worker_pid`（会脱钩） | 进程列表 + `task_runs` + 事件流 |
| 派了几次 | `status` | `SELECT * FROM task_runs WHERE task_id='<卡号>'` |

### 10.3 症状 → 机制归属（先判断"是机制还是故障"）

| 症状 | 优先怀疑的机制 | 排除动作 |
|---|---|---|
| `ready` 卡长时间没人派 | **不是故障**，是某一层门挡住了 | ①assignee 是真 profile 吗 ②在 `dispatch_profiles` 白名单里吗 ③全局/每 profile 并发满了吗 ④在 cooldown/熔断里吗 ⑤reclaim 掉过期锁了吗 ⑥**网关在跑吗**（dispatcher 在网关里） |
| 卡停在 `todo` | **正常**：等父卡 | 查 `task_links` 的父卡状态 |
| 卡莫名进 `triage` | **设计使然**：同因循环 ≥ 2 次 | 看 `block_recurrences` 与 `block_loop_detected` 事件 |
| 日志"claimed"但板上不动 | 串板（`current` 漂移） | 命令是否显式带 `--board` |
| 卡显示 `running` 但无进程 | 认领过期/崩溃 | 第七章 + 第九章回收 |
| 卡显示 `todo` 但 worker 在跑 | claim 静默失败 | 复核 claim 结果 |
| 宿主卡顿/OOM | 并发没设限 | 配 `max_in_progress`（第九章） |
| 时间戳排序崩 | 脏数据（ISO 文本混入 epoch 列） | 归一化为整数 epoch 秒 |

---

## 十一、配置键全表

`[源码]` 全部在 `config.yaml` 的 `kanban:` 段下，**读一次、重启生效**
（`_resolve_dispatcher_settings` 注释：read once at boot (restart to apply)）。

| 键 | 默认 | 作用 |
|---|---|---|
| `dispatch_interval_seconds` | `60` | dispatcher 轮询间隔；下限 1 秒 |
| `max_in_progress` | 未设→内存推导 | 全局并发上限（宿主内存小**必须**显式设） |
| `max_in_progress_per_profile` | 未设 | 每 profile 并发上限 |
| `max_spawn` | 未设 | 单轮最多派生数 |
| `failure_limit` | 2 | 连续失败熔断阈值 |
| `dispatch_stale_timeout_seconds` | `0`（禁用） | `running` 超时判定 |
| `reconcile_orphans` | `true` | 是否回收孤儿 `running` |
| `default_assignee` | 未设 | 给无 assignee 的 `ready` 卡兜底指派（未设=无限跳过） |
| `review_dispatch` | `true` | 是否自动派 `review` 车道 |
| `dispatch_profiles` | 未设（不限） | 白名单：只有这些 profile 的卡会被派 |

**设置方式**：用 `hermes config set`，**不要手改 `config.yaml`**（一个缩进错误就能弄坏在跑的网关）。

---

## 十二、判断「我的板安不安全」

按你的模式，回答这五个问题即可（全部可从 DB + 配置自证）：

| # | 问题 | 命令/位置 | 危险信号 |
|---|---|---|---|
| 1 | **有自动派单在跑吗？** | 网关是否运行；`kanban.dispatch_interval_seconds` | 你以为没有，其实网关一直在派 |
| 2 | **哪些卡会被自动碰？** | 选卡条件：`status IN ('ready','review') AND claim_lock IS NULL AND assignee 是真 profile` | 你的卡满足全部条件 → 会被抢 |
| 3 | **我的执行者名字会不会被匹配？** | `assignee` 值 vs `dispatch_profiles` 白名单 | assignee 是普通 profile 名 → 会被派 |
| 4 | **有并发上限吗？** | `max_in_progress` / `max_in_progress_per_profile` | 都没设 → 可能被派爆 |
| 5 | **绑项目了吗？** | `tasks.project_id` / `workspace_kind` | 非空 → 任务工作区形态改变（见第十三章） |

**结论**：如果 ①网关在跑 ②你的卡是 `ready` 且 assignee 是真 profile ③没配白名单
→ **你的卡会被自动派单**。这是"抢单"问题的全部机制来源。

---

## 十三、与「外部派单哨兵」模式的分工

有一类工作流**不用 Hermes profile 当 worker**，而是把卡派给**外部编码 Agent**
（如外部编码 CLI）执行。此时：

### 13.1 为什么必须绕开内置 dispatcher

内置 dispatcher 的 worker 是**该 profile 的 Hermes 实例**。若你另有外部执行器，
两者会**同时**认领同一张卡 → 两个 worker 写同一份代码 → 互相覆盖。

源码层面也印证这条路的历史纠葛：迁移手册 v2.0 明确**废弃了"员工 profile 制"**，
理由原文是——用 profile 当 worker「与网关自动派发纠缠不清，是抢单问题的源头」。

### 13.2 绕开的三条手段（按可靠性排序）

| 手段 | 做法 | 效果 |
|---|---|---|
| **① assignee 前缀错开**（最常用） | 你的卡 assignee 用自定义前缀（如 `xx-`），**不是**登记在册的 profile 名 | dispatcher 的 profile 门**直接跳过**（第八章 8.4）——卡永远不被内置派单器认领 |
| **② 白名单收窄** | `kanban.dispatch_profiles` 只列内置 worker 的 profile | 把家目录划成两半 |
| **③ 不用 `ready` 车道** | 卡停在 `todo`，由外部哨兵自己 promote+claim | 但 `todo` 语义是"等父卡"，会与依赖机制混淆（**不推荐**） |

**手段 ① 的副作用**：因为 assignee 不是真 profile，**内置 dispatcher 完全不会碰你的卡**，
所以你**必须自己保证派单**（定时任务 / 哨兵脚本）。这正是"外部派单哨兵"存在的技术原因。

> **重要**：手段 ① 生效的前提是「前缀确实错开」。若你的前缀恰好等于某个真实 profile 名，
> 门就失效了 —— 所以「前缀要取一个绝不会被注册成 profile 的名字」是**机制性要求**，
> 不是风格偏好。

### 13.3 你需要自己承担的三件事（内置 dispatcher 原本白送你的）

1. **promote**：父卡完成后把子卡从 `todo` 提到 `ready`（内置版靠 `recompute_ready` 每轮做）
2. **reclaim**：过期/孤儿认领的回收（内置版靠 reclaim 阶段）
3. **并发与熔断**：全局/每角色并发、冷却、熔断计数——**且计数必须落盘**
   （定时任务每轮是新进程，内存里的计数会清零 → 对同一卡无限重派）

### 13.4 两种模式对照

| | 内置 dispatcher | 外部派单哨兵 |
|---|---|---|
| worker 是什么 | 该 profile 的 Hermes 实例 | 外部编码 Agent |
| 由谁触发 | **网关**内嵌循环（网关停=停） | 定时任务 / 常驻脚本（**自己保证活着**） |
| 选卡条件 | 内置 SQL + profile 门 | 你自己写（**必须与内置版错开，否则双派**） |
| promote / reclaim | 白送 | **自己实现** |
| 状态计数器 | DB（`consecutive_failures`） | **必须自己落盘** |
| 怎么自证安全 | 看第八章的门 | 看第十二章五问 |

---

## 附录 A：命令速查

> 全部命令**必须显式带 `--board <板>`**（第二章 2.2）。

```bash
# ── 板 ──────────────────────────────────────────────
hermes kanban boards list                      # 列板
hermes kanban boards create <板名>              # 建板（不会自动绑项目）

# ── 卡 ──────────────────────────────────────────────
hermes kanban --board <板> create "<标题>" --body "..." --assignee <名字> --priority 10
hermes kanban --board <板> list [--status <状态>]
hermes kanban --board <板> show <卡号>           # 详情 + 评论 + 事件
hermes kanban --board <板> comment <卡号> "..."  # 留言（含交付说明）
hermes kanban --board <板> stats                # 各状态/各 assignee 计数 + 最老 ready 年龄

# ── 依赖 ────────────────────────────────────────────
hermes kanban --board <板> link   <子卡> <父卡>
hermes kanban --board <板> unlink <子卡> <父卡>   # ⚠ 慎用（6.3）

# ── 状态流转 ────────────────────────────────────────
hermes kanban --board <板> claim    <卡号> --ttl 7200   # 原子认领；不带重定向才看得见报错
hermes kanban --board <板> reclaim  <卡号>              # 释放孤儿/过期认领
hermes kanban --board <板> complete <卡号>
hermes kanban --board <板> block    <卡号>
hermes kanban --board <板> unblock  <卡号>              # blocked/scheduled → ready（父卡未完成则回 todo）
hermes kanban --board <板> schedule <卡号>              # 等时间（不是等人）
hermes kanban --board <板> promote  <卡号>              # 手动 todo/blocked → ready（恢复路径）
hermes kanban --board <板> request-review <卡号>        # 实现完成，等审查（不是阻塞）
hermes kanban --board <板> archive  <卡号>

# ── 派单与观测 ──────────────────────────────────────
hermes kanban --board <板> dispatch            # 手动跑一轮（reclaim→promote→spawn）
hermes kanban --board <板> tail <卡号>         # 跟随事件流
hermes kanban --board <板> watch               # 全板事件流
hermes kanban --board <板> runs <卡号>         # 历次派单记录
hermes kanban --board <板> diagnostics          # 活跃诊断项
```

`hermes kanban daemon` **已废弃**——dispatcher 在网关里，用 `hermes gateway start`。

## 附录 B：机制自查清单（可逐条打勾）

- [ ] 我知道看板的 DB 在 `<hermes家目录>/kanban/boards/<板名>/kanban.db`
- [ ] 我知道状态有 **9** 个，包括 `triage`/`scheduled`/`review`/`archived`
- [ ] 我知道 `dependency` 阻塞落到 `todo` 而不是 `blocked`
- [ ] 我知道 `recompute_ready` 会自动把依赖满足的卡提为 `ready`（不需要手动 promote）
- [ ] 我知道 `claim` 会**静默失败**，认领后必须复核
- [ ] 我知道孤儿 `claim_lock` 要靠 `reclaim` 释放，且会造成"永久不派"
- [ ] 我知道 dispatcher **跑在网关里**，网关停=不派单
- [ ] 我知道选卡条件是 `ready/review + 未认领 + assignee 是真 profile + 排序`
- [ ] 我知道 **assignee 写错 profile 名 = 卡永远不被派且不报错**
- [ ] 我知道有 cooldown / `recent_success` / `active_pr` 等重派守卫
- [ ] 我知道并发默认按内存推导（每 worker 512 MB），小内存宿主必须显式设上限
- [ ] 我知道连续失败默认 **2** 次熔断，且只有成功才清零
- [ ] 我知道 `unlink` 会让子卡立刻变 `ready`（双派事故的经典路径）
- [ ] 我知道跨项目操作必须显式带 `--board`（`current` 是全局单值）
- [ ] 我知道直查 DB 前必须 `PRAGMA table_info`（字段名与别处不同）
- [ ] 我答得出第十二章的五个问题

---

*本文只描述机制，不含任何项目特定信息。落地步骤、安装、日常使用与踩坑清单见
《Hermes 自动化工作流 · 迁移手册》。*

---

## 勘误与补录（本机实测，2026-10-13）

> 核实基准：本机 Hermes 源码 `%LOCALAPPDATA%\hermes\hermes-agent\`（`hermes_cli/kanban_db.py`、
> `hermes_cli/kanban_db_dispatch.py`、`gateway/kanban_watchers_dispatcher.py`）+ `hermes kanban --help` 实跑。
> 本文正文的机制描述（9 态、block kind 四元组、TTL 15min、熔断 2、循环上限 2、512MB/worker、
> 限流冷却 300s、选卡 SQL、recompute_ready、review_dispatch 默认开、dispatcher 在网关内）经源码逐条比对**全部吻合**。
> 以下为本版本实测与正文的出入，正文原文不改，冲突处以本节为准。

### E1 附录 A 命令速查不完整

实测 `hermes kanban --help` 还含：`init`、`assign`、`reassign`、`set-model`、`edit`、`reopen-review`、
`request-changes`、`specify`、`decompose`、`heartbeat`、`log`、`context`、`attach` 族、`notify-*` 族、
`gc`、`repair`、`swarm`、`assignees`。**命令全集以 `hermes kanban --help` 为准**，勿以附录 A 为排除性依据。
其中与正文强相关的两个：`assign <id> <profile|none>` 确实存在（正文未列）；**`reopen` 不存在**
（恢复路径 = `promote` / `unblock` / `reclaim`，CLI 会提示"Did you mean: reopen-review?"）。

### E2 §8.4 "静默不派且不报错"已过时（利好）

现行源码对 assignee 非真实 profile 的候选卡会记事件 `skipped_nonspawnable`（payload 含 assignee；
同值去重，不会每 tick 刷屏）。因此"ready 长期没人派"**可以用 `hermes kanban --board <板> tail <卡号>`
直接确诊**是 profile 门跳过，不再只能盲猜。排查口诀仍成立，只是多了事件流这条实锤路径。

### E3 §十一 配置键全表缺漏

源码实存而表中未列的键：`kanban.worker_log_rotate_bytes`（默认 2 MiB）、
`kanban.worker_log_backup_count`（默认 1）、`kanban.blocked_stale_hours`（默认 24，diagnostics 用）、
`kanban.orchestrator_profile`（decompose 扇出后根卡归属）。
另：TTL/熔断等常量多数有环境变量覆盖入口（如 `HERMES_KANBAN_CLAIM_TTL_SECONDS`）。

### E4 §8.4 default_assignee 的"配置了会发生什么"正文未写

正文只写了未配置时的行为。源码（`_resolve_default_assignee` → `_apply_default_assignee`）证实：
**配置为真实 profile 名时，dispatcher 每轮会给无 assignee 的 ready 卡自动写上该名字并派出**（事件
`assigned`, source=`kanban.default_assignee`）。共享板 + 外部执行者工作流下这是抢单事故源：
建卡忘填负责人 → 被自动兜底派出。本 kit 部署机的处置是把该键置空（空串/未设 = 关闭，卡安静等待）。

### E5 §十 排障补充：`list --json` 不含 claim_lock

实测任务 JSON 共 27 键，**无** `claim_lock` / `claim_expires` / `consecutive_failures`。
孤儿锁判别按正文第七章"裸跑 claim 看 `lock=` 报错"执行；另有 `hermes kanban --board <板> diagnostics`
可列出含 claim_lock 异常在内的活跃诊断项，作为零 SQL 巡检信号源。直查 DB（§3.2 提醒）不受影响。
