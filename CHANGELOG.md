# Changelog

> Hermes Workflow Kit 的版本变更与融合历史。`README_FUSION_HISTORY.md`（v4.0 详细变更）已废弃，所有变更在此累积。

---

## v4.6.1（2026-09-13）— preflight 调度器检测假阴性修复

| # | 改动 | 落点 |
|---|------|------|
| 1 | **调度器判定改三重信号**：① `hermes gateway status` 出现 `Gateway process running` → ② `gateway_state.json` 里 `gateway_state=running` 且 pid 存活（兜底）→ ③ `pgrep -f "kanban daemon"`；三者皆无才判未确认。修掉"gateway 明明在跑却判 DEGRADED"的**假阴性**——原实现匹配的是**否定措辞** `gateway process detected`，真实正例文案是 `Gateway process running (PID ...)`。同时把 python 解析器提前到 §3 之前（原实现里 §3 用到的 `$PY` 尚未定义，兜底分支形同虚设） | `scripts/preflight.sh` |
| 2 | 顺带记录一次真实故障与处置：本机 gateway 计划任务启用但**启动失败**（`platforms.api_server.enabled=true` 且无 `API_SERVER_KEY` → 启动守卫拒绝 → 整个 gateway `startup_failed`，dispatcher 与 cron 全停）。按修复 B 禁用该平台（`hermes config set platforms.api_server.enabled false`）后 `hermes gateway restart`，gateway 恢复运行、cron 立即正常执行 | 本机 Hermes 配置（非套件内容） |

### 测试

- `bash scripts/preflight.sh` → **READY（exit 0）**；`--require-dispatcher` 亦 READY
- `tests/run_tests.sh`：12 段 31 项全通过

---

## v4.6.0（2026-09-13）— 路线 A 批次 C：执行体切原生 worker + 角色/模型策略 + 归档监控

批次 C 目标：把**默认执行体**从外部 CLI 换成平台原生 worker，修正角色→profile 的过时策略，
并把归档/保留/监控收口到平台能力。本批次完成后，套件只保留平台不具备的三件事：
**流程纪律 + 文档骨架 + 语义去重与边界校验**。

| # | 改动 | 落点 |
|---|------|------|
| 1 | **默认执行体切原生 worker**：新增 §6.0 明确「平台原生 worker 为默认，外部 CLI（`claude -p`/`codex`）为可选后端」；§6.1 姿势表重排；§6.2 改标题为「外部 CLI Print 模式（可选后端）」 | `Hermes_制度层.md` §六 |
| 2 | `USAGE.md` §五 同步：默认 = `kanban-dispatch` 建卡 → dispatcher 派生 worker；外部 CLI 与 pipeline 降为"可选后端" | `USAGE.md` |
| 3 | `agent-bridge` 技能定位声明：`parallel` = 原生看板卡路径；`claude/claude-bg/codex` = 可选后端（无心跳/无回收/无审计，用则自补状态回写） | `skills/agent-bridge/SKILL.md` |
| 4 | **角色→profile 策略修正（两个真 bug）**：① profile 存在性判断用 `grep -qx` 匹配表格首列（原 `^name$` 永不匹配 → 重复创建）；② 删除写死的 `provider: anthropic` + `sonnet`，改为 `DEFAULT_MODEL`/`DEFAULT_PROVIDER` 传入，留空则**继承全局配置**（原写法在本机 provider=custom/deepseek 下生成不可用 profile） | `scripts/sync-roles-to-profiles.sh` |
| 5 | **归档/保留/监控收口平台**：制度层 §三 新增归档纪律（先终态再 archive、归档期禁止重试）与监控纪律（`stats`/`watch`/`notify-subscribe`，不另建监控表）；`kanban-executor` 新增 §5 归档保留与监控对照表（重复执行、调度可用性、状态冲突、卡滞积压） | `Hermes_制度层.md`、`skills/kanban-executor/SKILL.md` |
| 6 | 重试归属注释：`pipeline.py` 常量区注明"这里的重试只覆盖 pipeline 自身阶段，worker 侧熔断归平台" | `scripts/pipeline.py` |

### 路线 A 完成后的定位（三层收口）

| 层 | 归属 | 内容 |
|---|---|---|
| 执行 / 调度 / 状态 / 重试 / 评审 / 归档 / 监控 | **Hermes 平台** | 看板、dispatcher、worker、断路器、review 门、`gc`/`stats`/`watch` |
| 流程纪律 | 套件 | 七阶段准入准出、Tier 分级、协商触发、三态汇报、军规 |
| 平台没有的三件事 | 套件自研（**唯一该自研的部分**） | `scope-check.py`（文件边界互斥 + 语义指纹去重）、`preflight.sh`（调度存活闸门与降级）、文档骨架与引用校验 |

### 测试

- `tests/run_tests.sh`：12 段 31 项全通过
- 单元测试：`test_pipeline.py` 29 + `test_scope_check.py` 29 + `test_kanban_dispatch.py` 9

---

## v4.5.0（2026-09-13）— 路线 A 批次 B：对齐平台（状态机 / 重试 / 评审门 / 心跳 / 交接）

批次 B 目标：把套件自造的机制（状态枚举、重试计数、巡检周期、完成自述）**交还平台**，
只保留平台没有的那部分（流程纪律、边界校验、语义去重、文档骨架）。

| # | 改动 | 落点 |
|---|------|------|
| 1 | **状态机统一为平台八状态**（`triage/todo/ready/running/blocked/review/done/archived`），废弃 `IN_PROGRESS`/`IN_REVIEW` 别名（= `running`/`review`），卡片状态与看板不再漂移 | `Hermes_制度层.md` §三、模板 04/08、`kanban-executor` |
| 2 | **心跳纪律入制度**：由平台 worker 执行的任务每小时 `kanban_heartbeat`；平台规则「running >4h 且 1h 无心跳 → 回收重排」写进任务卡要求，长任务不再被静默回收 | `Hermes_制度层.md` §三、`kanban-executor` §2 |
| 3 | **重试/熔断交还平台**：套件只规定"人工修复闭环第 2 轮上浮协商"（军规 8），worker 侧连续失败由平台熔断（`--max-retries` / `failure_limit` 默认 2；`--max-runtime` 超时重排队）；`kanban-dispatch` 透传 `--max-retries / --max-runtime / --completion-contract / --skill`，套件不再叠加自造重试计数 | `Hermes_制度层.md` §三、`scripts/kanban-dispatch.py` |
| 4 | **评审门替代自述式完成**：卡必须走 `request_review` → 评审（可 `review_dispatch` 派 sdlc-review）→ 通过才 `complete`；`--completion-contract`（OWNER/REPO / PR URL）把「完成」绑到 PR 与 CI 门 | `Hermes_制度层.md` §三、`project-workflow` S6、`kanban-executor` §4 |
| 5 | **交接协议改卡评论**：跨 Agent 交接以 `kanban_comment`（重派后 worker 读全线程）+ `attach` 为准，TASK.md 降为本地工作稿；明确 **scratch 工作区完成即删** 的产物丢失陷阱（须 `worktree`/`dir:` 或声明 artifacts） | `Hermes_制度层.md` §6.5 |
| 6 | **巡检/回收重写为平台事实**：原子认领、`reclaim`、bounded retry（默认 3）、熔断后处置流程；删除自造的「30 分钟巡检 / READY>24h 强派 / IN_PROGRESS>8h 回收」 | `kanban-executor` §1–§3 |
| 7 | `slugify` 修复：fallback 也做规范化，避免大写/非法字符进入 worktree 分支名 | `scripts/kanban-dispatch.py` |

### 测试

- `tests/run_tests.sh`：**12 段 31 项全通过**（新增段：kanban-dispatch 建卡契约）
- 新增 `tests/test_kanban_dispatch.py` 9 例（slug / 命令拼装 / 平台开关透传 / 三闸门与退出码）

---

## v4.4.2（2026-09-13）— 路线 A 批次 A：闸门落地 + 真 bug 修复 + 文档对齐

背景：确定**路线 A**（拥抱 Hermes 原生能力，把执行/调度/状态交还平台），批次 A/B/C 依次执行。
批次 A 目标：止血——把"文档承诺但不存在"的能力补成真的，把实测到的真 bug 修掉，把漂移的文档对齐。

| # | 改动 | 落点 |
|---|------|------|
| 1 | 新增 **S4 文件边界互斥闸门** `scope-check.py`：三种输入（tasks.yaml / 04 任务卡 md / JSON）、保守重叠判定（同目录不同通配尾缀不算冲突，其余宁可误报）、缺 files_scope 即拒发、**语义指纹** `sha256(目标+边界+验收)` 输出 | `scripts/scope-check.py`（新） |
| 2 | 新增 **派发前环境闸门** `preflight.sh`：hermes CLI / 看板可读写 / **调度器（dispatcher）存活** / python / 角色库 / scope-check 就绪；三态 READY/DEGRADED/NOT_READY + `--json` + `--require-dispatcher` | `scripts/preflight.sh`（新） |
| 3 | 新增 `kanban-dispatch.py`：tasks.yaml → **原生看板卡**，三闸门串联（环境→边界→幂等），语义指纹作 `--idempotency-key`，输出每卡 `t_xxxxxxxx` 作为 S4 准出证据 | `scripts/kanban-dispatch.py`（新） |
| 4 | **真 bug 修复**：`cmd_kill` 遇空/非数字 pid 时把 `""` 传给 `update_active`，jq `tonumber` / python `int("")` 抛错导致 active.json **静默不更新**（实测 Traceback + 状态丢失）→ pid 归一化 + python 侧容错 | `scripts/agent-bridge.sh` |
| 5 | **测试假失败修复**：`cross-language list \| grep -q` 命中即关管道 → 上游吃 SIGPIPE → pipefail 下退出码 141，表现为"功能正常却报失败"。全部改 `grep ... >/dev/null`；段号改 `seg()` 动态生成，消灭手写分母漂移 | `tests/run_tests.sh` |
| 6 | **消除"文档承诺 vs 实现"落差**：`parallel` 从占位实现（`warn 简化实现` + `return 1`）改为真路径（转发 `kanban-dispatch.py`，参数向后兼容并新增 `--dry-run/--json/--assignee/--workspace`）；SKILL 执行规则按实测行为重写 | `scripts/agent-bridge.sh`、`skills/agent-bridge/SKILL.md` |
| 7 | **删除不实声明**：cron `kanban-board-watchdog`（从未落地）→ 改为 dispatcher 事实（跑在 gateway 里）+ preflight 检测 + 显式降级为串行+人工对账 | `skills/kanban-executor/SKILL.md` |
| 8 | **角色库自定位修复**：`CLAUDE_AGENTS_DIR` 解析改为"存在的那个优先"（会话里导出的 `HERMES_HOME` 不再把自定位带偏）；`load_roles` 改惰性调用，无关子命令不再误告警「未发现任何角色」 | `scripts/agent-bridge.sh` |
| 9 | **S4 闸门接线**：制度层 §三 新增"派发前双闸门 + 幂等键纪律"、§6.3 改为原生卡路径；`project-workflow` S4 补准入/准出闸门；`kanban-executor` §0 重写为"双闸门 + 幂等 + 准出证据" | `Hermes_制度层.md`、2 个 SKILL |
| 10 | **文档漂移清理**：`PROJECTS` 硬编码段 → `config/projects.yaml`；`hermes pipeline resume`（不存在的子命令）→ `--from-stage`；`F:` 盘 → 实际路径；角色库说明删重复 §九 与失效 `ROLES` 数组引用；版本口径统一（制度层/模板索引去掉内嵌版本号，`CHANGELOG.md` 为唯一源） | `autonomous-delivery/SKILL.md`、`DEPLOY.md`、`通用角色库说明.md`、`Hermes_制度层.md`、`模板库/00` |
| 11 | 文档补新脚本与闸门命令 | `README.md`、`DEPLOY.md` |

### 测试与验证

- `tests/run_tests.sh`：**11 段 26 项全通过**（新增：空 PID 回归、scope-check CLI 契约、preflight 契约）
- 单元测试：`test_pipeline.py` 29 例 + `test_scope_check.py` 29 例全通过
- **真实平台幂等验证**：临时板 `scope-smoke` 建卡 → 同指纹二次派发 → 返回**同一** `t_5e39a7cd`、板上仍 1 条 → 硬删临时板（默认板未受影响）

### 兼容性

- `agent-bridge.sh` 既有子命令与输出不变；`parallel` 参数向后兼容（新增可选参数）
- pipeline 报告 JSON 格式不变；CLI 参数不变

---

## v4.4.1（2026-09-09）— S4 看板硬闸门（修复"漏板"缺陷）

背景：hljjt_hcgccloud 走工作流时 S4 只写 TASK.md + worktree 派发，从未执行 `hermes kanban create`，
导致看板上看不到新增任务（当日 T-003/T-004 等 5 卡全部漏板），且 watchdog 只扫板上卡、无法兜底。

| # | 改动 | 落点 |
|---|------|------|
| 1 | 新增 §0 建卡派发硬闸门：create → list 自验 → 写 TASK.md → 认领 的固定顺序 + 可照抄命令模板（--idempotency-key / --initial-status running 防双跑）+ 会话收尾漏板自查 | `skills/kanban-executor/SKILL.md` |
| 2 | 命令速查表补 create 用法一行 | `skills/kanban-executor/SKILL.md` |
| 3 | S4 加"顺序硬约束 + 准出闸门"：缺任一看板卡 id 即 S4 未准出，禁止进入 S5 / 禁止声称已建卡 | `skills/project-workflow/SKILL.md` |
| 4 | 任务卡模板新增"看板卡 ID"必填栏（空 = 未准出），"当前状态"降格为缓存并注明事实源 | `Hermes模板库/04_任务卡模板.md` |

---

## v4.4（2026-09-09）— SOLID/重构落地（报告 ≤8 分项全量整改）

依据《理论落地分析报告》（综合 7.4/10）对全部 ≤8 分项实施修复。

### 改动

| # | 分项 | 改动 | 落点 |
|---|------|------|------|
| 1 | B4 6→9 | Status 常量类 + stage_index() 序号比较，消灭 `from_stage <= "02"` 字符串序比较；状态字面量唯一来源 | `scripts/pipeline.py` |
| 2 | D1 5→9 | CommandRunner 协议 + SubprocessRunner/FakeRunner 依赖注入；阶段函数全部走注入 runner | `scripts/pipeline.py` |
| 3 | A3 7→9 | agent-bridge roles/list/monitor 支持 `--json` 机器可读输出（jq 优先 python 兜底，数据走 stdin 规避 MSYS 路径陷阱） | `scripts/agent-bridge.sh` |
| 4 | B3 7→9 | orchestrate 拆为 resolve_config / setup_worktree / run_stage_with_retry / summarize / cleanup_worktree 五段 | `scripts/pipeline.py` |
| 5 | B2 7→9 | cmd_claude / cmd_claude_bg 写 TASK.md 提取为共用 write_task_md()；orchestrate 移除与 stage_04 重复的 skip 分支 | `scripts/agent-bridge.sh` `pipeline.py` |
| 6 | C2 6→9 | PROJECTS 硬编码迁出 → `config/projects.yaml`；load_projects() 纯函数（显式路径权威，搜索：参数→env→部署目录→仓库） | `config/projects.yaml` `pipeline.py` |
| 7 | C3 7→9 | 语言清单迁出 → `config/languages.yaml`（markers/extensions/categories），cross-language.sh 零硬编码清单 | `config/languages.yaml` `scripts/cross-language.sh` |
| 8 | C4 7→9 | Stage dataclass 注册表驱动编排；新增阶段 = 注册一行，orchestrate 不变（OCP） | `scripts/pipeline.py` |
| 9 | D2 6→9 | `tests/test_pipeline.py` 29 个单元测试（注册表/状态/配置加载/重试分支/阶段函数/编排端到端），接入 run_tests.sh 段7 | `tests/test_pipeline.py` |
| 10 | E2 6→9 | check-references 升级章节级契约：`xxx.md §anchor` 校验目标章节真实存在（中文/阿拉伯/混合锚点规范化 + AGENTS.md/SOUL.md 别名）；失效模式清单外置 `config/stale-patterns.txt` | `scripts/check-references.py` |
| 11 | E1 8→9 | update_active 加 mkdir 原子锁（含 30s 死锁清理），防止并发 claude-bg 覆盖 active.json | `scripts/agent-bridge.sh` |
| 12 | E3 6→9 | 全局可变状态清零：PROJECTS 模块级字典删除，改 load_projects() 纯函数 + 调用方注入 | `scripts/pipeline.py` |

### 测试

- `tests/run_tests.sh` 扩展为 9 段（新增：pipeline 单测 / cross-language 清单加载 / --json 契约）
- `python -m unittest discover -s tests` → 29/29 通过
- check-references 负向验证：注入 `§九十九`/`§六.99` 假锚点可捕获，恢复后全绿

### 兼容性

- pipeline 报告 JSON 格式不变（status 字符串原值保留）
- CLI 参数全部保留，新增 `--projects-config`
- agent-bridge 文本输出不变，`--json` 为可选标志

---

## v4.1（2026-09-08）— 精简版

### 改动

| # | 改动 | 落点 |
|---|------|------|
| 1 | SOUL.md 移除与 AGENTS.md 重复的"编码委派规范"与"红线条目" | `Hermes_主人格.md` 115 行 |
| 2 | 6 个 SKILL.md 各精简"任务传递姿势"/"失败兜底"/"红线"重复段，统一引用 AGENTS.md §六/§九 | `skills/*/SKILL.md` |
| 3 | 删除"v4.0 改动说明与使用指南"，拆为 `CHANGELOG.md` + `USAGE.md` + `DEPLOY.md` | 顶层 |
| 4 | 删除 README.md（仅 1 行简介，价值低于其存在） | 顶层 |
| 5 | 通用角色库说明.md 删除 §九"32→16 角色差异表"（v4.0 已上，无价值） | `通用角色库说明.md` |

### 行数变化

| 文件 | v4.0 | v4.1 | 变化 |
|------|------|------|------|
| `Hermes_主人格.md` | 117 | 115 | -2 |
| `skills/project-workflow/SKILL.md` | 96 | 78 | -18 |
| `skills/agent-bridge/SKILL.md` | 299 | 237 | -62 |
| `skills/autonomous-delivery/SKILL.md` | 366 | 356 | -10 |
| `README_改动说明与使用指南.md` | 269 | 0（已删除） | -269 |
| **本轮合计** | — | — | **-361** |

> 完整目标：总行数 5401 → ~3300。本轮完成约 7%。

---

## v4.3（2026-09-09）— 工程健壮性加固

> 对应评估报告 §2.7 四项短板（零测试/依赖脆弱/中文路径/无 CI）逐一处理。

### 改动

| # | 改动 | 落点 |
|---|------|------|
| 1 | **修复实质 bug**：`update_active` 无 jq 时原仅 warn 后什么都不做（任务追踪数据静默丢失）；现改为 python 兜底，且代码走 `-c`、JSON 走 stdin/stdout、文件操作由 bash 完成——绕开 Windows Python 收到 MSYS 路径写到错误位置的坑 | `scripts/agent-bridge.sh` |
| 2 | `load_roles` 兼容 `description: \|`（YAML 块格式）——已部署的 `~/.claude/agents/*.md` 存在此格式，原实现会提取出 `\|` | `scripts/agent-bridge.sh` |
| 3 | agent-bridge.sh 增加入口守卫（被 source 时不触发 main），支持测试内嵌调用 | `scripts/agent-bridge.sh` |
| 4 | 新增引用完整性检查器：扫描全库相对引用核对目标存在 + 检测已知失效模式（模板 11 等），负向测试验证可抓断链 | `scripts/check-references.py`（新增） |
| 5 | 新增最小测试集 6 段：shell 语法 / py 编译 / 角色加载（16 个）/ pipeline dry-run / 引用完整性 / update_active 双路径单测 | `tests/run_tests.sh`（新增） |
| 6 | pipeline.py 新增 `--path` 参数（免改 PROJECTS 配置临时指向项目），修复 orchestrate 直接污染全局 PROJECTS 的小问题 | `scripts/pipeline.py` |
| 7 | `.gitattributes` 强制 LF（.sh/.py/.md/.yaml/.json），消除 CRLF 跨平台脚本报错 | `.gitattributes`（新增） |
| 8 | 临时产物目录 `.test-tmp/` 入 .gitignore | `.gitignore` |

### 验证

- 全部 6 段测试逐段绿灯（含块格式解析、去重+状态迁移、断链负向检测）
- 脚本语法/编译全过；`update_active` python 兜底在 Windows + Git Bash 环境实测写读正常

### 未做（明示）

- **中文目录英文化**（评估报告 P3）：涉及全库引用与用户习惯，收益/风险比低，维持现状
- **CI 接入**：当前为本地测试集（`bash tests/run_tests.sh`），接入 GitHub Actions 留待有远端仓库需求时

---

## v4.2（2026-09-09）— 角色清单自动同步 + 导览重建

### 改动

| # | 改动 | 落点 |
|---|------|------|
| 1 | agent-bridge.sh 移除硬编码 ROLES/ROLE_DESC 数组，改为运行时动态扫描 `~/.claude/agents/*.md` frontmatter——新增/删除角色自动生效，无需改脚本 | `scripts/agent-bridge.sh` |
| 2 | 通用角色库说明.md：删除重复的 §九（与 §八完全相同）、修复"模板 11"失效引用、扩展流程改为"无需改脚本" | `通用角色库说明.md` |
| 3 | 模板 04 任务卡：§五"执行上下文"并入 §四"派发通知"（原 4 项有 3 项重复），消除双份维护 | `Hermes模板库/04_任务卡模板.md` |
| 4 | 重建 README.md 为项目导览：架构图 + 快速开始 + 目录说明 + 单一事实源约定表 | `README.md` |

### 决策记录

- 模板 02 HLD / 03 DD / 05 会议纪要经逐节核查：字段不重复、结构紧凑，**保留原样**（其中的"召集通知/派发通知"与信息表的重复属有意设计——发送载荷需自包含）。
- v4.1 的行数基线修正：v4.0 实际总行数 ~6659（此前 5401 为低估，漏算部分文件）；v4.1 后 ~5721。

---

## v4.0（2026-09-08）— 融合首发版

### 融合来源

- **v3.0**：本仓库原版（七阶段状态机 + 追踪矩阵 + 建投专属规范）
- **自动化迁移手册**：`hermes+claude code 自动化工作流`目录（三流水线 + 32 角色库 + pipeline.py + agent-bridge.sh）

### 融合策略

- **场景定位**：建投系 Java 微服务二次开发 → 跨项目通用（任意语言/任意规模）
- **流程骨架**：保留 v3.0 七阶段状态机作为 Tier 2 入口
- **自动化能力**：迁移手册的 pipeline.py / agent-bridge.sh / 桌面 Kanban 引入为"可选增强"
- **角色库**：32 建投专属 → 16 通用（覆盖前后端/DBA/PM/审查/构建）
- **编码规范**：建投专属红线 → 通用最佳实践（不可变/小文件/TDD/80% 覆盖）
- **跨语言**：新增 `cross-language` 技能，按语言特性分发规范

### 模板 / 技能 / 角色

| 类别 | 数量 | 关键变化 |
|------|------|---------|
| 模板 | 12 | 保留 1-8；新增 9（HANDOFF）、10（version.md）、11（跨语言清单）；00 改为通用编码规范 |
| 技能 | 6 | 保留 3（project-workflow / kanban-executor / codegraph-review）；新增 3（autonomous-delivery / agent-bridge / cross-language） |
| 角色 | 16 | 32 → 16 个跨项目通用角色 |

### 关键引入文件

```
Hermes_主人格.md（→ SOUL.md）
Hermes_制度层.md（→ AGENTS.md）
Hermes模板库/（00~11 共 12 个模板 + 索引）
skills/（6 个 SOP）
scripts/（pipeline.py + agent-bridge.sh + cross-language.sh + sync-roles-to-profiles.sh）
通用角色库/（16 个 .md）+ 通用角色库说明.md
```

---

## 历史迁移（已不可逆，存档）

- v3.0 → v4.0：去掉建投专属命名（"芦哥"→"工程师"）；替换建投红线（白名单/禁 MyBatis）→ 通用最佳实践
- v2.x → v3.0：引入追踪矩阵 + 七阶段准入准出
- v1.x：初版（七阶段状态机雏形 + 模板库）
