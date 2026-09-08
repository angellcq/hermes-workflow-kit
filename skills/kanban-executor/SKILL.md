---
name: kanban-executor
description: "Use when 看板任务需要自动认领/巡检/回收. Kanban 任务生命周期自动化."
version: 1.0.0
platforms: [windows, linux, macos]
---

# Kanban Executor Skill

自动管理 Hermes Kanban 任务生命周期：未认领分配、心跳保活、超时回收、状态验证闭环。

## 核心能力

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
| 查看未分配任务 | `hermes kanban list --json` 过滤 ready+null assignee |
| 分配任务 | `hermes kanban assign <id> <profile>` |
| 查看任务详情 | `hermes kanban show <id>` |
| 标记完成 | `hermes kanban complete <id> --summary "..."` |
| 标记阻塞 | `hermes kanban block <id> "reason"` |
| 查看运行中 | `hermes kanban runs --active` |

## 在工作流中的位置与配合

本技能是**执行层的任务生命周期管理者**，不负责拆需求、不改码。

- **上游**：`project-workflow` 在 S4 阶段拆出任务卡后，交给本技能建卡派发（`kanban create` + 写 TASK.md + 认领）
- **下游**：编码代理（Claude Code/Codex）产出后，本技能做**完成验证闭环**（git diff 非空 + 编译通过 + changed_files 核对），通过才标 DONE
- **旁路**：`codegraph-review` 在编码代理改码**之前**被调用评估波及面，评估报告作为任务卡附件
- **兜底**：cron 任务 `kanban-board-watchdog`（每 30 分钟）自动执行本技能的巡检逻辑（认领悬空卡、回收超时任务）

**调用时机**：只要看板出现 ready/blocked/超时任务，或 S4 需要建卡派发，就加载本技能。
