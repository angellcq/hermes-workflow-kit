---
name: kanban-executor
description: "Use when 看板任务需要自动认领/巡检/回收. Kanban 任务生命周期自动化."
version: 1.0.0
platforms: [windows, linux, macos]
---

# Kanban Executor Skill

自动管理 Hermes Kanban 任务生命周期：未认领分配、心跳保活、超时回收、状态验证闭环。

## 核心能力

### 0. 建卡派发（S4 唯一入口 · 硬闸门）

**任何任务在写 TASK.md / 建 worktree / 派发编码代理之前，必须先 `hermes kanban create` 上板。**
TASK.md 里的"当前状态"字段仅是缓存，看板才是唯一事实源；只写 TASK.md 不上板 = 漏板失职，
且 watchdog 巡检只扫**已在板上**的卡，从未上板的卡不会有任何机制兜底。

标准顺序（每张卡，命令照抄勿即兴发挥）：

```bash
# ① 建卡 —— 拿到 t_xxxxxxxx 才算这张卡存在
hermes kanban create "T-NNN: <动词+对象+结果>" \
  --body "TASK.md: <绝对路径> | 来源: <PRD/DD#章节> | files_scope: <边界>" \
  --workspace worktree --branch claude/<slug> \
  --idempotency-key T-NNN --initial-status running --json
#    ↑ 防重复建卡            ↑ 手动 claude -p 派发时用 running 占位，
#                              否则 ready 卡会被 dispatcher 认领后双跑

# ② 自验卡片确实在板上（输出必须含 ① 返回的 id，否则视为建卡失败）
hermes kanban list --json | python -c "import sys,json;[print(t['id'],t['status'],t['title'][:40]) for t in json.load(sys.stdin) if t['id']=='<①返回的id>']"

# ③ 写 TASK.md 落盘 → 派发（dispatcher 自动认领，或手动 claude -p）

# ④ 编码代理收口后立即回板（完成验证闭环见 §4）
hermes kanban complete <id> --summary "<验收结论>" --metadata '{"commit":"<hash>","changed_files":[...]}'
```

约束：
- 标题前缀 = 任务卡 ID（`T-003: ...`），看板 ↔ 任务卡双向可回溯
- `--idempotency-key` 一律填任务卡 ID，补账/重跑天然去重
- **会话收尾自查**：diff `.hermes/tasks/` 新增 TASK.md 与本会话建卡 id 清单，
  发现漏板的当场补建并回补状态，禁止留给下次
- 已合并的漏板历史任务补账：`create --initial-status running` 后立刻 `complete --summary "<commit+验收结论>"`；
  未验收完的建卡后 `block <id> "<待办原因>"`，不许默默留在 ready

### 1. 未认领自动分配 (Auto-Claim)

```bash
# 查找所有 ready + unassigned 的任务
hermes kanban list --json | python -c "import sys,json; [print(f\"{t['id']} {t['title'][:50]}\") for t in json.load(sys.stdin) if t['status']=='ready' and not t.get('assignee')]"

# 分配给 default profile
hermes kanban assign <task_id> default
```

**执行策略：**
- 每次巡检时检查 `status=ready AND assignee=None` 的任务
- 如果 body/TASK.md 信息完整 → 直接分配给 default
- 如果信息不完整 → 补全 body（从历史记录/评论中提取）后再分配
- 记录分配动作到审计日志

### 2. 心跳保活 (Heartbeat)

daemon worker 通过 `process(action=poll)` 监控 Claude Code 进程状态：

```bash
# 检查运行中的 daemon 进程
hermes kanban runs --active
```

**保活规则：**
- 每 30 分钟执行一次巡检
- active 任务超过 4 小时无进展 → 标记 BLOCKED 并通知用户
- daemon 进程异常退出 → 尝试重启（不重复超过 2 次）

### 3. 超时回收 (Timeout Recovery)

| 状态 | 触发条件 | 处理方式 |
|------|---------|---------|
| BLOCKED > 1 检查周期 | 无人认领或 worker 挂起 | 重新分配 + 通知用户 |
| READY > 24h | 未被认领 | 强制分配给 default |
| IN_PROGRESS > 8h | Claude Code 进程已终止 | 回收并创建新卡重试 |

**回收流程：**
1. `hermes kanban show <task_id>` 查看阻塞原因
2. 判断是否可恢复（代码逻辑错误需要重派 vs 网络问题可重试）
3. 可恢复 → `hermes kanban reopen <task_id>` 重新派发
4. 不可恢复 → `hermes kanban block <task_id> "需人工介入：XXX"`

### 4. 完成验证闭环

Claude Code 完成任务后，必须验证产出再标记 complete：

```
1. git diff --stat HEAD          # 确认有变更
2. dotnet build                  # 编译通过
3. 核对 changed_files            # 与 TASK.md 一致
4. hermes kanban complete <id> --summary "..."
```

**零产出判定：** `git status --short` 和 `git diff --stat HEAD` 均为空 → 委派失败 → STOP 转手动 patch。

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
- **兜底**：cron 任务 `kanban-board-watchdog`（每 30 分钟）自动执行本技能的巡检逻辑（认领悬空卡、回收超时任务）

**调用时机**：只要看板出现 ready/blocked/超时任务，或 S4 需要建卡派发，就加载本技能。
