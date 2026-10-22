# Hermes Workflow Kit · 进化方案 v5.0（草案）

> 提出人：Hermes ｜ 日期：2026-10-22 ｜ 修改范围：本仓库（`hermes-workflow-kit`）
> 输入：①《Agent 与命令体系》（CC 子 agent / slash 命令参考）②《Hermes 看板机制说明书》③《Hermes 自动化工作流迁移手册 v2.0》+ 本仓 v4.5.3 现状
> 性质：**增量进化**。不推翻七阶段状态机、不改编排语义、不删既有资产。

---

## 〇、一句话结论

kit 现在是「**人/agent 手工派单 + 指纹唤醒处置**」，缺的是「**派单器 + 哨兵 + 产出校验**」这层执行底座；
三份文档里 ③ 正是这层底座的完整实现（6 道守卫 + 三态产出校验 + 哨兵三控），② 已在 v4.5 并入，
① 补的是角色**原生加载**姿势（`claude --agent`）。因此 v5.0 = **把 ③ 的执行底座吸收进 kit，并把角色落地从 Hermes profile 换成 CC agent，同时把卡体系扩到全生命周期**。

---

## 一、现状盘点（逐项带证据）

| 能力 | kit v4.5.3 现状 | 证据（文件:行） |
|---|---|---|
| 看板 9 态机制 | 已并入，且带本机源码纠偏 | `skills/kanban-executor/references/kanban机制说明书.md`（v4.5 并入） |
| 外部执行者模式（assignee=前缀非 profile） | 已立铁律 | `skills/kanban-executor/SKILL.md:21` |
| 建卡硬闸门（不上板禁派发） | 已有 | `SKILL.md:38`（§0） |
| 巡检指纹器（monitor 零唤醒） | 已有，7 类信号 + ack 去重 | `scripts/kanban-watchdog.py`（206 行） |
| **自动派单哨兵** | **无**。派单靠会话内手工 `claude -p` 或 agent-bridge；promote/reclaim/并发/熔断由"cron 唤醒的 agent"用自然语言处置 | `SKILL.md:179-187`（自承担清单） |
| **派单守卫②③（claim 前查状态 / claim 后复核）** | 只有文字铁律，**无代码强制** | `SKILL.md:28-30` vs 无实现文件 |
| **产出校验（防零产出假 done）** | 只有一句文字判据 `git status`+`git diff`，**无代码、无验证型卡豁免** | `SKILL.md:143` |
| 角色**加载** | ❌ **角色名只被写进 TASK.md 文本，从未真正加载角色定义**：`claude -p "读 TASK.md 并执行"`，未用 `--agent` | `scripts/agent-bridge.sh:245-250` |
| 角色**落地形态** | 同步成 **16 个 Hermes profile**（`hermes profile create` + `AGENT.md`） | `scripts/sync-roles-to-profiles.sh:9-12` |
| 配置集中 | 无 `config.env`，参数散在各脚本/文档 | 无该文件 |
| 端到端流水线 | `pipeline.py` 759 行，6 阶段 | `scripts/pipeline.py:3-14` |
| 全生命周期卡 | 卡只在 S4 拆、只有开发类卡；无分析/概设/详设/验收/收尾卡 | `Hermes_制度层.md` §1.1 vs `04_任务卡模板.md` |
| Owner 字段 | "指派人"存在，但 `assignee` 已语义占位为**路由键** | `04_任务卡模板.md:17` + `08_看板卡片模板.md:6` |
| 状态口径 | 文档 5 词（TODO/IN_PROGRESS/IN_REVIEW/DONE/BLOCKED）↔ 板 9 态对照 | `08_看板卡片模板.md:5` |

### 三份文档的增量判定

| 文档 | 判定 | 处理 |
|---|---|---|
| ② 看板机制说明书 | **已覆盖**（v4.5 并入，且 kit 版有本机源码纠偏，比附件版新） | 不重复并入；只把附件里 diff 到的两处表述回填 |
| ③ 迁移手册 v2.0 | **最大缺口**：`install.sh` / `config.env` / `dispatch_claude.sh`（6 守卫）/ `card_produce_check.py`（三态）/ `kanban_auto_dispatch.py`（哨兵三控）/ `kanban_tick.py`（日志断层可观测） | 吸收为 P2+P3，**代码级移植而非重写** |
| ① Agent 与命令体系 | 角色库已是 CC agent frontmatter 格式；缺注册目录、`--agent` 调用、`AGENT_TEAMS` 开关、以及"Agent 工具写文件必被权限弹窗卡死（只能用 `claude -p --agent` 或 workflow 脚本 `agent()`）"这条硬事实 | 吸收为 P4 |

---

## 二、五个必须拍板的裁决（先定这些，再动手）

| # | 裁决点 | 选项 A（推荐） | 选项 B | 为什么必须先定 |
|---|---|---|---|---|
| **D1** | `assignee` 语义 | **保持路由键**，且进一步用它承载"派给哪个 CC agent"（`wf-backend-developer`）；**负责人由 assignee 前缀派生**，不新增 Owner 字段 | 另立 Owner 手填字段 | 改 `assignee` 语义会击穿防抢单闸门（`profile_exists` 判定）；而 Owner 手填会与 assignee 打架、两处事实源 |
| **D2** | 角色落地形态 | **11 个留下（分两档使用）+ 5 个剔除**，全部加 `wf-` 前缀装 `~/.claude/agents/`，用 `claude --agent` 原生加载 | 16 个全装 / 维持 16 个 Hermes profile | profile 制是抢单源头（③ §10.1 明写废弃）；但 5 个协调类角色与 kit 铁律冲突（含"让 CC 去建卡改派"），必须剔除。评估见 §八 |
| **D3** | 工作区策略 | ✅ **已定：双策略**，默认「目录域」（`WF_AGENT_DIRS`，一人一目录）+ 可选「worktree」；策略写进卡面 `workspace: dir\|worktree` | 只留 worktree / 只留目录域 | worktree 在 Windows 有锁残留/依赖污染/游离分支三连坑（③ §5.6），不该做默认 |
| **D4** | 卡载体 | **保留** `.hermes/tasks/<ID>/TASK.md` 为详版，板 `body` 只放「TASK.md 路径 + files_scope + DoD + 来源」；哨兵按 body 里的路径读文件 | 全量写进板 body | 现有 `SKILL.md:59` 与 `04` 模板都按 TASK.md 走；改载体=全量返工且职责错位（卡是索引，文档是内容） |
| **D5** | `pipeline.py` | **保留但标 `deprecated`**（阶段间无产出校验，③ §10.1 判死），复用其 6 阶段语义到「收尾卡模板」 | 删除 | 它被 `tests/` 与 `autonomous-delivery` 技能引用，删了要连带改 4 处，收益为 0 |

---

## 三、进化路线（P1–P5，按依赖排序，可独立上线）

### P1 · 卡体系扩到全生命周期（纯文档，零代码风险）

| 动作 | 落点 |
|---|---|
| 04 模板追加 5 字段：`阶段 / Owner / assignee(路由键) / 交接产物 / 失败重试次数` + 阶段码规范 `T-<模块>-<AN/HLD/DD/DEV/QA/CLS>-<序号>` | `Hermes模板库/04_任务卡模板.md` |
| 08 模板追加：**三态 ↔ 9 态映射表**、Owner vs assignee 双字段说明、`workspace` 策略字段 | `Hermes模板库/08_看板卡片模板.md` |
| 制度层 §二 追加 3 条：①六段卡各建一张 ②Owner/assignee 双字段 ③依赖必须落板 `link` | `Hermes_制度层.md` §二 |
| 依赖链落板命令与边数自检（`T 张卡 = T-1 条边`，扇出另计） | `skills/kanban-executor/SKILL.md` §0 |
| 新增卡模板：`11_验收卡模板.md`、`12_收尾卡模板.md`（③ 附录 C.2 的验收纪律可整段吸收） | `Hermes模板库/` |

**验收**：`check-references.py` 全绿；模板编号引用一致；制度层新增条文不与 §1.1 冲突（逐条对照）。

---

### P2 · 派单器（把「守卫」从文字变成代码）

**新增** `scripts/dispatch-lane.sh`（骨架取自 ③ 的 `dispatch_claude.sh`，约 190 行）：

| 守卫 | 实现 | 退出码 |
|---|---|---|
| ① 全程显式 `--board` | 板名作必填参数 | — |
| ② claim 前查状态防双派 | `status==running` → 拒派 | 3 |
| ③ claim 后复核 | 非 `running` → 拒派（多半是父卡未完成） | 3 |
| ④ 派单前快照 | 交给 `card_check.py snapshot`（**同一量只一处实现**） | — |
| ⑤ 默认注入 `--allowedTools`（逗号分隔）+ `WF_MAX_OUTPUT_TOKENS` | 脚本内默认值 | — |
| ⑥ **产出校验三态** | `card_check.py verdict` → 0 produced / 1 EMPTY→block / 2 skip | 透传 |

**新增** `scripts/card_check.py`（移植 ③ 的 `card_produce_check.py`，保留三条踩坑注释）：
- 验证型卡**只匹配标题**（正文含"验收/只读"会把修复卡误判成验证型 → 放过零产出）
- 快照必须 Python 统一生成（bash 侧 CRLF vs Python 侧 LF ⇒ 守卫曾长期不生效）
- 判定器异常退出（非 0/1/2）必须显式降级为 skip 并在评论里写明，不许静默 fail-open

**改造** `scripts/agent-bridge.sh`：
- `cmd_claude` 改为 `claude --agent <prefix><role>` 原生加载（修 D2 的空转缺陷，`agent-bridge.sh:245`）
- 保留 `-p` + `TASK.md` 防空任务姿势（与现状一致）
- 增加 `--board/--card` 参数，内部转调 `dispatch-lane.sh`（**单一派单入口**，禁止两套路径）

**验收**：用假执行器（记录参数/按场景决定是否提交的 `claude` 替身）跑全部分支，覆盖：已 running 拒派、claim 未生效拒派、零产出→block、有产出→done、验证型卡零产出→done、worker exit=7→block。

---

### P3 · 哨兵（让板自己动起来 —— 本次问题的根治）

**新增** `scripts/card-sentinel.py`（移植 ③ `kanban_auto_dispatch.py`，四件事）：
1. 前缀过滤：只碰 `WF_AGENT_PREFIX` 开头的卡（= 与内置 dispatcher 错开，零抢单）
2. 补并发：`WF_MAX_CONCURRENT` / `WF_MAX_PER_AGENT=1`
3. **状态落盘**：冷却与熔断计数写 `logs/sentinel_state.json`（cron 每轮新进程，内存计数必清零 → 无限重派）
4. 交给 `dispatch-lane.sh`（哨兵只派，不验收）

**新增** `scripts/sentinel_tick.py`（cron 入口）：每轮**无条件**落盘 `logs/tick.log`。
> 价值实证：③ §6.4 记录过"卡挂 20 小时、真因是主机休眠"——日志里 19.5 小时时间戳断层一眼定位。kit 现在的 `kanban-watchdog.py` 不看这个。

**改造** `scripts/kanban-watchdog.py` 增两个信号：
- `ASSIGNEE_DRIFT <task>`：ready 卡 assignee 为空、或命中真实 profile（= 有被网关抢单的风险）
- `SENTINEL_DEAD`：state 文件 mtime 超阈值（哨兵僵死但无人知）

**改造** `skills/kanban-executor/SKILL.md`：
- 删除"promote/reclaim/并发熔断由 agent 手工做"的自承担叙述，改为"由哨兵承担，agent 只处置哨兵上报的异常"
- 补 `claim` 而非 `--initial-status running` 的规则（无 `claim_lock/claim_expires` 的 running 卡会被 `reconcile_orphaned_running` 在 60 秒内打回 ready）

**新增** `config/wf.env.example`（单点配置，③ 附录 B 全表照抄 + kit 自有项）：
```
WF_BOARD / WF_REPO / WF_AGENT_PREFIX / WF_MAX_CONCURRENT / WF_MAX_PER_AGENT
WF_COOLDOWN_SECONDS / WF_FAIL_FUSE / WF_POLL_SECONDS / WF_AGENT_DIRS
WF_CLAUDE_ARGS / WF_CLAUDE_MODEL / WF_MAX_OUTPUT_TOKENS / WF_VERIFY_KEYWORDS
WF_WORKSPACE_MODE=dir|worktree   # D3 裁决项
```

**验收**：一张示例卡从 `ready` 自动走到 `running`→`review`→（agent 验收）`done`；`--dry-run` 不污染状态；kill 哨兵 → `SENTINEL_DEAD` 报出。

---

### P4 · 角色与入口重构

| 动作 | 落点 |
|---|---|
| **新增** `scripts/install-claude-agents.sh`：把 `通用角色库/*.md` 装到 `~/.claude/agents/<prefix>*.md`（幂等、`--dry-run`、`--dir` 可改） | `scripts/` |
| `sync-roles-to-profiles.sh` 标 `deprecated`（保留 3 个版本周期，文件头写废弃原因与替代） | `scripts/sync-roles-to-profiles.sh` |
| 制度层 §八「16 角色库」改口径：角色**不是 Hermes profile**，是 CC agent；补 `AGENT_TEAMS=1` / `defaultMode` 自检三条命令 | `Hermes_制度层.md` §8.1/§8.4 |
| §6.1 三种委派姿势增补第 4 种「**哨兵派单**」（P3 交付后成为默认），原三姿势降级为手动调试用 | `Hermes_制度层.md` §六 |
| 新增部署前置检查：`claude --version` + agents 目录计数 + `AGENT_TEAMS` + 项目 `.claude/settings.json` 存在性 | `DEPLOY.md` |

**关键硬事实（必须写进 kit，来自 ①）**：CC 子 agent 由 **Agent 工具**调用时写文件会被权限弹窗卡死（`default/bypassPermissions/dontAsk/auto` 四种模式实测全部失败），唯一可行路径是 `claude -p --agent` 或 workflow 脚本的 `agent()`。⇒ **kit 一律用 `claude -p --agent`，禁止指示用户"用 Agent 工具派发"**。

---

### P5 · 收尾与回归防线

| 动作 | 落点 |
|---|---|
| `tests/run_tests.sh` 增 3 组：dispatch-lane 假执行器分支 / card_check 三态 / 哨兵 `--dry-run` 不污染 | `tests/` |
| 脚本计数・文件计数期望值同步（**历史上"加脚本忘改期望值"造成过假红**） | `tests/run_tests.sh`、`check-references.py` |
| `CHANGELOG.md` 记 v5.0：每项改动标「来源文档 ③/①」+ 落点 + 验证结论 | `CHANGELOG.md` |
| `README.md` 目录表补 3 个新脚本 + `config/wf.env.example` | `README.md` |
| `USAGE.md` 增「哨兵模式」一节（装 → 改 wf.env → 建卡 → 看 tick.log） | `USAGE.md` |

---

## 四、落地顺序与灰度

```
P1（纯文档，当天可完） → 部署到 hljjt 验证引用完整性
      ↓
P2（派单器）→ 用假执行器单测 → 真项目单卡手派验证
      ↓
P3（哨兵）→ --dry-run 观察 3 轮 → 单卡灰度（并发=1）→ 全量
      ↓
P4（角色原生加载）→ 单角色灰度（backend-developer）→ 16 角色
      ↓
P5（回归 + 版本）→ tests 全绿 → CHANGELOG v5.0 → 各项目重新部署
```

**部署口径**（沿用现有机制）：kit 改完 → `hermes-workflow-update` 技能把 GitHub 套件镜像同步到各项目 `.hermes/`（hljjt / jtdb / jt-business-partner-mcp / KSITest / xhhk 等），每个项目改 `wf.env` 的板名+仓库路径+子目录映射。

**每包独立可回滚**：新增文件为主（P2/P3），改造仅 `agent-bridge.sh` / `kanban-watchdog.py` / `sync-roles-to-profiles.sh` 三个文件，回滚 = 恢复这三个 + 停 cron。

---

## 五、必须随方案一起写进 kit 的坑（全部来自三份文档实测）

| # | 坑 | 落点 |
|---|---|---|
| 1 | `claim` 会**静默失败** → 必须复核 `status=running` | P2 守卫③ |
| 2 | 无 `claim_lock/claim_expires` 的 `running` 卡会被 `reconcile_orphaned_running` **60 秒内打回 ready** | SKILL.md（P3） |
| 3 | `unlink` 瞬间满足依赖 → 子卡立刻 `ready` → 与网关并发双派 | SKILL.md 铁律 5（已有，补命令示例） |
| 4 | `--initial-status running` 不能替代 `claim` | P3 |
| 5 | 建卡带 `--project` → 产物进游离分支，**永不进主线且看板显示 done** | 制度层 §二 + DEPLOY 检查（禁止项） |
| 6 | `.worktrees/` 必须进 `.gitignore`；`node_modules` 符号链接会让"隔离"在依赖层失效 | 制度层 + DEPLOY 自检 |
| 7 | Windows：`python3` 可能是 Store 存根（要真跑一次验证）、MSYS 路径要转 `D:/x`、`taskkill //PID` 不可靠 | P2/P3 脚本注释 + 排错手册 |
| 8 | 验证型卡**只按标题**豁免零产出（正文含关键词会误放行修复卡） | `card_check.py` |
| 9 | 哨兵冷却/熔断计数**必须落盘**（cron 每轮新进程） | P3 |
| 10 | 子进程输出 `CLAUDE_CODE_MAX_OUTPUT_TOKENS` 默认 2048 会截断长报告并崩 | P2 `wf.env` |
| 11 | CC 子 agent 经 **Agent 工具**写文件必被权限弹窗卡死 | P4 制度层 |
| 12 | 同一量只能一处实现（快照/CVS 指纹） | P2 `card_check.py` 头注释 |

---

## 六、明确不做（边界）

1. **不引入 Hermes profile 当 worker**（③ 已判废，抢单源头）。
2. **不改看板 9 态 schema**、不改 `task_links` 依赖机制。
3. **不重写 `pipeline.py`**（只标 deprecated + 复用其阶段语义）。
4. **不动 16 个角色的内容**（只改落地形态与加载方式）。
5. **不引入 MCP / 不做 dashboard / 不改 agent-bridge 的 parallel 编排**——与本方案正交。
6. **不把 `Owner` 塞进 `assignee`**（D1）。

---

## 七、验收标准（对照原始 7 条需求）

| 需求 | 落点 | 状态 |
|---|---|---|
| 1 六阶段各建卡 | P1（04/08/11/12 模板 + 制度层 §二） | 方案齐 |
| 2 负责人字段 | P1（Owner），D1 裁决 | 待拍板 |
| 3 依赖链无断链无环 | P1 + `link` 落板 + 边数自检 | 方案齐 |
| 4 三态 + 流转规则 | P1（三态↔9 态映射表，11 条流转规则） | 方案齐 |
| 5 角色分工与交接 | P1（交接产物字段）+ 制度层 §四 | 方案齐 |
| 6 派发容错 | P2（6 守卫）+ P3（哨兵三控）+ 12 条坑清单 | 方案齐 |
| 7 子代理评估 | P4 结论：**不建虚拟员工/不建 profile；子 agent 仅用于验收复核与只读调研** | 待拍板 D2 |
| 增量不破坏 | 新增 5 文件 + 改造 3 文件；不动 6 项 | 方案齐 |

---

## 八、裁决记录（2026-10-22）

### 8.1 D1 · 三份文档对 `assignee` 的原话

| 文档 | 原话 | 含义 |
|---|---|---|
| ② 机制说明书 §一 | 「**`assignee` 不是"负责人备注"，是路由键** —— 它的值是 **Hermes profile 名**，dispatcher 靠它决定启动哪个 profile 的 worker。名字写错 = 卡永远不被派（且不报错）」 | 路由语义，非人名字段 |
| ② §8.4 | 「派单前会检查 `assignee` 对应的 **profile 是否存在**；不存在 → 跳过这张卡，没有报错、没有事件」 | 防抢单闸门就是靠这条 |
| ② §13.2 手段① | 「assignee 用自定义前缀（如 `xx-`），**不是**登记在册的 profile 名 → dispatcher 的 profile 门直接跳过」 | 外部执行者模式的机制基石 |
| ③ 迁移手册 §三 | 「卡的 `assignee` **必须等于**你 `~/.claude/agents/` 里真实存在的 agent 名，且带 `WF_AGENT_PREFIX` 前缀」「前缀（默认 `cc-`）是**防抢单**机制」 | 比我们现状更进一步：assignee 直接编码"派给哪个 CC agent" |
| ① Agent 与命令体系 | 只讲 `subagent_type` / Agent 工具 / `/agent` 命令 | **不涉及看板 assignee**，对 D1 无输入 |

**裁决（A，改良版）**：不新增 `Owner` 字段，`assignee` 一个字段两用但语义明确——
- `wf-<角色>`（如 `wf-backend-developer`）= 派给对应 CC agent，归属 **Claude Code**
- `hm-<用途>`（如 `hm-analysis`）= Hermes 主会话自己做（分析/概设/详设/验收/收尾），归属 **Hermes**
- 卡面「负责人」栏**由前缀派生渲染**（模板规则写死），不手填 → 单一事实源，两字段不会打架
- 机制收益：既满足"每张卡有明确负责人"，又让哨兵天然知道该唤谁

### 8.2 D2 · 16 个角色的逐项评估（本机实测基线）

**环境实测**：`claude --version` = 2.1.300，原生支持 `claude --agent <agent>`；
`~/.claude/agents/` **已有 187 个 agent**（其中 185 个是 `category__name` 命名），**裸名 `code-reviewer.md` 已被占用**；
`settings.json` 里既无 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` 也无 `defaultMode`（不影响 `--agent`，只影响 agent teams）。

| 档 | 角色 | 判定 | 理由 |
|---|---|---|---|
| **A 直接可用**（进卡 assignee 路由，8 个） | backend-developer / frontend-developer / fullstack-developer / mobile-developer / dba / devops / test-engineer / build-error-resolver | ✅ 留下 | 实现与专用修复，正是"编码代理"该干的；按角色路由后派单指令不必每次重写技术栈上下文 |
| **B 限定用途**（3 个） | code-reviewer（**必须改名 `wf-code-reviewer`**）/ security-reviewer / architect | ✅ 留下，仅用于验收复核与设计顾问 | 给验收提供第二视角（配合换模型 = 真正的交叉检查）；architect 只读、只做 DD 技术选型咨询 |
| **C 与 kit 职责冲突**（5 个） | project-manager / loop-operator / planner / tdd-guide / docs-writer | ❌ **剔除** | 见下 |

**C 档为什么必须剔除（不是"可选不装"）**：

| 角色 | 冲突点（证据） |
|---|---|
| `project-manager` | 正文核心能力直接写「任务分配：`hermes kanban create` + `assign`」「进度跟踪：`hermes kanban list`」（`通用角色库/project-manager.md:18-20`）——与 kit 铁律「**Hermes 独占看板生命周期，编码代理不碰看板状态**」正面冲突。装成 CC agent = 让被派发方自己去建卡改派，双跑与状态污染必发 |
| `loop-operator` | 与 kit 的 cron + `kanban-watchdog.py` 指纹机制重叠；两套循环监控并存会互相抢单/重复唤醒 |
| `planner` | S2/S3 设计与计划是 Hermes 的职责（制度层 §一），交由 CC 等于把决策权外包；且 `opus` 成本高 |
| `tdd-guide` | TDD 已作为**闸门**写进制度层 §二 与 `编码规范_跨语言.md`（v4.5.2 改造），角色化只会重复且可能覆盖项目降级策略 |
| `docs-writer` | PRD/HLD/DD/验证报告是 Hermes 的交付物（模板 01-10），不是编码代理产出 |

**结论：对原工作流是"有益"还是"破坏"？**
- 走 **CC agent**（A+B 共 11 个）→ **有益**：角色 = 独立 system prompt + 工具白名单 + 模型分槽，让"派给后端"真的生效（现状 `agent-bridge.sh:245` 只是把角色名写进 TASK.md，等于空转）。
- 走 **Hermes profile**（现状）→ **破坏**：16 个 profile 会进 dispatcher 的认领池，正是抢单源头。
- 走 **16 个全装** → **轻度破坏**：C 档 5 个会与 kit 制度层抢职责（尤其 project-manager 会教 CC 改看板）。
- 三条可规避风险：① 统一 `wf-` 前缀（裸名 `code-reviewer` 已被占）；② 每个角色头部加「项目根 `AGENTS.md`/`CLAUDE.md` 优先于本角色技术栈段落」；③ A/B/C 三档在 `通用角色库说明.md` 里显式标注，防止下次又被全量同步。

### 8.3 D3 · 已定

双策略：默认**目录域**（`WF_AGENT_DIRS` 一人一目录，`WF_MAX_PER_AGENT=1` 强制同角色串行），
高冲突项目在卡面写 `workspace: worktree` 走隔离检出；worktree 模式附带强制自检（`.worktrees/` 进 `.gitignore`、禁 `--project`、出口做 `git worktree list` 残留检查）。

### 8.4 最终裁决表（2026-10-22 芦哥拍板，按此执行）

| # | 裁决项 | 结论 | 对方案的修正 |
|---|---|---|---|
| D1 | assignee 语义 | 单一字段双用：`cc-<角色>`→Claude Code，`hm-<用途>`→Hermes；负责人栏由前缀派生渲染，**不新增 Owner 字段** | §一/§二 表格以本条为准 |
| D2 | 角色落地 | `~/.claude/agents/` + `claude --agent` 原生加载；**只装 11 个**（A 档 8 + B 档 3） | P4 |
| D2-a | C 档 5 个角色处置 | **移到 `通用角色库/deprecated/`**（可回滚），安装脚本不扫描该子目录；`tests/run_tests.sh` 的「预期 16 个」改为 **11** | P4 + P5 |
| D2-b | agent 前缀 | **`cc-`**（与迁移手册一致）。注意 `~/.claude/agents/` 裸名 `code-reviewer.md` 已被占用，故装成 `cc-code-reviewer.md`，天然不撞 | P4 |
| D4 | 卡载体 | 保留 `.hermes/tasks/<ID>/TASK.md` 详版 + 板 body 放指针 | — |
| D5 | pipeline.py | 保留、标 `deprecated` | — |
| D6 | 历史卡 assignee | **一律不回填**，只管新卡（老卡留 `skipped_nonspawnable` 现状，不做批量改派） | 移除原 R2 建议 |
| D7 | 部署节奏 | **只改 kit 仓库；等 P5 全绿后一次性部署到所有项目**（不在 P1/P2 中间灰度铺开） | §四 落地顺序改为「kit 内全绿 → 一次部署」 |
| D8 | 提交纪律 | **Hermes 负责 commit，不 push**；push 等芦哥发话 | — |
| D9 | 环境改动 | **不动 `~/.claude/settings.json`**（`--agent` 在 2.1.300 原生可用，无需 AGENT_TEAMS/defaultMode；该文件归 cc-switch 管） | P4 移除该项自检 |
| D10 | 谁来写代码 | P1 纯文档由 Hermes 写；**P2/P3/P4 的脚本仍派 CC lane 实现**，Hermes 只出 TASK.md + 独立验收（tests 绿 + 假执行器实测） | §四 |
