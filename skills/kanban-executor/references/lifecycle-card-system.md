# 全生命周期任务卡体系（六段卡 · 三态映射 · 派发失败矩阵）

把任务卡从「只覆盖代码开发」扩到「分析→概设→详设→开发→验收→收尾」，且**不改编板 9 态 schema**。
适用：用户要求「卡覆盖全生命周期」「每张卡有负责人」「依赖链无断链」「状态只有三态」。

## 1. 两个字段，不是一个：assignee 是路由键，负责人由前缀派生

`assignee` 的语义是**机制路由键**（dispatcher 靠它决定 spawn 谁），不是负责人备注；
把它改成人名会击穿防抢单闸门（`profile_exists` 判定）。所以**不新增 Owner 字段**，改为前缀派生：

| assignee 前缀 | 归属（卡面「负责人」栏渲染） | 谁执行 |
|---|---|---|
| `cc-<角色>`（如 `cc-backend-developer`） | Claude Code（角色名） | 对应编码 agent |
| `hm-<用途>`（如 `hm-analysis`） | Hermes | 主会话自己做（分析/设计/验收/收尾） |

前缀取 `cc-`（对齐编码 CLI 生态与既有 lane 约定）；换前缀要**全链路同时改**（建卡命令、派发器白名单、巡检信号、模板示例），
否则卡会静默变成 `skipped_nonspawnable` 谁也派不动。

单一事实源：卡面负责人手填 = 迟早与 assignee 打架。

## 2. 阶段码与卡清单（标准 Tier 2）

ID 规范 `T-<模块>-<阶段码>-<序号>`，阶段码：`AN` 分析 / `HLD` 概要设计 / `DD` 详细设计 / `DEV` 开发 / `QA` 验收 / `CLS` 收尾。旧 `T-NNN` 不回溯改名。

| 阶段 | 卡 | Owner | assignee | 前置 | 交接产物 |
|---|---|---|---|---|---|
| 需求分析 | `AN-1` 澄清+冻结歧义清单 | Hermes | `hm-analysis` | 无 | PRD + 追踪矩阵（US↔设计↔卡↔验证） |
| 概要设计 | `HLD-1` | Hermes | `hm-design` | AN-1 | HLD（组件/接口/选型+备选） |
| 详细设计 | `DD-1` | Hermes | `hm-design` | HLD-1 | DD（行号锚点/口径/红线/files_scope）、DEV 卡边界 |
| 代码开发 | `DEV-1..n` | Claude Code | `cc-<角色>` | DD-1 | 分支 commit + done-flag + DoD 勾选 |
| 验收测试 | `QA-1` | Hermes（+换模型复核） | `hm-verify` | 全部 DEV | 交付验证报告 + 看板 comment 证据 |
| 交付收尾 | `CLS-1` | Hermes | `hm-close` | QA-1 | 文档入库 + 追踪矩阵闭环 + 复盘 + 板归档 |

DEV 并行前提：`files_scope` 交集为空；同文件域串行用依赖边表达，不靠记忆。

## 3. 三态 ↔ 板 9 态映射（卡面三态，板面真名）

| 卡面（人看） | 板真态 | 出现条件 |
|---|---|---|
| 待执行 | `todo` | 父卡未完成 |
| 待执行 | `ready` | 父卡全 done，可派 |
| 待执行（异常） | `blocked` / `scheduled` / `triage` | 派发失败达上限 / 等时间 / 需分诊 |
| 正在运行 | `running` | claim 成功（写 claim_lock+claim_expires） |
| 正在运行（等验收） | `review` | DEV 交付、验收人未接单 |
| 已完成 | `done` → `archived` | 验收通过 complete；收尾卡 archive |

## 4. 流转规则（谁触发 / 前置 / 命令）

| # | 从 → 到 | 触发者 | 前置 | 命令 |
|---|---|---|---|---|
| 1 | — → todo | Hermes 建卡 | 上游 DD 完成、字段齐 | `create --assignee <lane>` + `link` |
| 2 | todo → ready | 板自动 | 父卡全 done | 无（`recompute_ready`）；卡死时 `promote` |
| 3 | ready → running | 派发器 | 父卡全 done、assignee 命中 lane、无同卡存活进程、并发未满 | `claim --ttl 3600` |
| 4 | running → running | 派发器 | 每 <15min | `heartbeat <id>` |
| 5 | running → review | 执行方/派发器代写 | lane 退出码 0 且 `git diff` 非空 | `request-review <id>` |
| 6 | review → running | 验收人 | 验收开始 | `claim <id>` |
| 7 | review → ready | 验收人 | 验收不通过（附证据） | `request-changes` / `reopen-review` |
| 8 | running → done | 验收人 | DoD 逐条 + 独立构建/实测证据 | `complete --summary "<证据>"` |
| 9 | running → blocked | 派发器 | 失败≥3 或 lane 崩×2 | `block <id> "<原因>"` |
| 10 | blocked → ready | Hermes | 原因解除 | `unblock <id>` |
| 11 | done → archived | 收尾卡 | 报告归档 + 追踪矩阵闭环 | `archive <id>` |

禁止：`ready→done`（跳级）、`todo→running`（依赖未满足）、`running→ready`（除 TTL 回收并留 comment）。

## 5. 依赖落板与自检

`hermes kanban --board <板> link <子卡> <父卡>`（边在 `task_links`，`tasks` 表没有 depends_on 列）。
父卡未 done 时子卡被压回 `todo`，父卡全 done 后自动 `ready`——依赖由板强制，不靠文字。
自检：线性骨架 5 条边 + DEV 扇出/扇入 2n 条，`T 张卡 ≈ T-1 + 2n` 条边；**没有孤立卡、没有环**。

## 6. 派发失败矩阵（每格都是踩过的）

| # | 失败形态 | 机制根因 | 兜底 |
|---|---|---|---|
| F1 | 派给不想派的 agent | assignee 命中真实 profile | 只用 lane 白名单；建卡后 `dispatch --dry-run` 必须 `Spawned: 0` |
| F2 | 配置漂移导致抢单 | 有人填了 `default_assignee` | 建卡必带 assignee；巡检加 `ASSIGNEE_DRIFT` 信号 |
| F3 | 下游卡先跑 | 依赖只在文字里 | 依赖一律 `link` 落板；派发器只读板上 parents |
| F4 | 板状态与实况脱节 | 手工 lane 不回写 | 派发器统一 `claim` + 心跳 + `request-review` |
| F5 | 卡 60s 内被打回 ready | 无 claim_lock 的 running 被 `reconcile_orphaned_running` 回收 | 只用 `claim`，不用 `--initial-status running` |
| F6 | TTL 到期双跑 | 心跳缺失 | TTL 3600 + 10min 心跳 + 派发前扫同卡存活进程 |
| F7 | 静默零产出 | 权限模式未开 `acceptEdits` / 端点拒答 | `git status`+`git diff --stat` 双空 → 重试≤2 → block |
| F8 | 崩溃×2 自动 block | 端点 400/拒答 | 不 unblock 重派（抢同 worktree）；转人工 lane 交付后 complete |
| F9 | 执行端不可用 | 模型/凭据失效 | 派发前 1 条探活；失败即 block + 告警，不空转 |
| F10 | 并发写同一文件 | files_scope 重叠 | 建卡校验交集为空；`max_in_progress_per_profile` 限并发 |

## 7. 子代理放哪里

- **用**：验收复核（必须换模型——同模型自验等于没验）、大规模只读调研（输出易污染主上下文）。
- **不用**：需求/概设/详设（需用户对话决策权，subagent 无提问权）、收尾归档（机械 3-5 条命令）、
  开发（已有外部编码 lane，再套一层 = 双倍开销 + 状态两处维护）。
- **绝不**建「虚拟员工 profile」：profile 就是 dispatcher 的派发单元，等于给抢单开入口。

## 8. 落地时的口径裁决（避免同一问题反复问用户）

推进这套卡体系时，下列几项用户已定过口径，**不必再逐次确认**，只在偏离时才回头问：

| 项 | 口径 | 理由 |
|---|---|---|
| 角色落地形态 | 装到 `~/.claude/agents/` 用 `claude --agent` 原生加载 | 建 Hermes profile = 开抢单入口 |
| 角色清单 | 只装「实现/修复/审查」类；**协调类角色（项目经理、循环监控、计划、TDD 方法、文档撰写）一律剔除并移到 `deprecated/`** | 它们的正文会指示编码代理去调 `kanban create/assign`，与「Hermes 独占看板生命周期」冲突 |
| 历史卡 | **不回填 assignee**，只管新卡 | 回填会批量改板状态账，且老卡本就跑完了 |
| 校验断言 | 角色/脚本数量断言随清单同步改（测试里是写死数字） | 改清单不改断言 = 假红 |
| 部署节奏 | 整套改完、测试全绿后**一次性**部署到各项目，不在包与包之间灰度铺开 | 半成品部署比晚部署贵 |
| 提交 | 由 Hermes `commit`，**不 push**；push 等用户发话 | 用户口径 |
| 环境文件 | 不动 `~/.claude/settings.json`（`--agent` 原生可用，不需要 agent-teams 开关；该文件归 cc-switch 管） | 避免踩用户配置 |
