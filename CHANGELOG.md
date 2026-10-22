# Changelog

> Hermes Workflow Kit 的版本变更与融合历史。`README_FUSION_HISTORY.md`（v4.0 详细变更）已废弃，所有变更在此累积。

---

## v5.0-P2（2026-10-22）— 派单器（守卫硬实现 + 三态产出校验）

背景：kit 过去的派单是"会话里手工敲 `claude -p`"，三个实测问题——①派单不收尾（工人零产出被当完成，
改动只躺工作区、被下一个 worker 覆盖）；②`hermes kanban claim` 静默失败无人知（工人在跑、看板显示
todo、卡被再派一次，两个 worker 写同一份文件）；③角色定义从未真正加载（只写进 TASK.md 文本）。
本笔把①②从文字规则变成代码（六道守卫 + 三态产出校验判定器），③只做接口预留（P4 切 `claude --agent`）。

| # | 改动 | 落点 |
|---|------|------|
| 1 | 新增 Python 公共层：`load_config`（wf.env 解析，环境变量 > wf.env > default）/ `native_path`（MSYS `/c/xx` → `C:/xx`，git-bash 路径传原生 python 曾 chdir 失败）/ `find_hermes`（WF_HERMES → which → 裸名兜底），同一个量只有一处实现 | `scripts/wf_common.py`（新增） |
| 2 | 新增产出校验判定器：`snapshot` 子命令输出 `HEAD sha\t工作区指纹`（md5 of sorted porcelain 行），`verdict` 子命令按固定顺序判定三态（SKIP_PRODUCE_CHECK→非 git→HEAD 变→指纹变→标题命中验证型关键词→取不到卡内容按有风险→EMPTY）；三条硬约束：验证型卡只匹配标题禁配正文 / 快照必须 Python 统一生成 bash 只透传（bash CRLF、Python LF 曾致指纹永不相同守卫失效）/ 异常退出不许静默 fail-open | `scripts/card_check.py`（新增） |
| 3 | 新增派单器 `dispatch-lane.sh`：六道守卫（①全程显式 --board 防 current 指针漂移串板 ②claim 前查 running 状态防 dispatcher+手动双写 ③claim 后复核状态防静默失败再派 ④派单前快照/native_path 归一/取不到显式降级 ⑤WF_CLAUDE_ARGS 默认逗号分隔工具白名单+CLAUDE_CODE_MAX_OUTPUT_TOKENS=32000 防 2048 截断 ⑥三态收尾 produced=complete / EMPTY=block+两次快照评论 / skip=complete / 判定器异常=显式降级 skip+留痕 / worker 非零退出=block+透传码）；工人名自动补 WF_AGENT_PREFIX 前缀 | `scripts/dispatch-lane.sh`（新增） |
| 4 | `cmd_claude` 改单一派单入口：新增 `--board`/`--card` 可选参数，带 `--card` 时转调 dispatch-lane.sh（认领→执行→收尾全链路），无 `--card` 保持旧的纯执行模式不破坏现有调用；**禁止**第二条独立派单路径 | `scripts/agent-bridge.sh` |
| 5 | 新增派单器配置样例（18 键全注释：WF_BOARD/WF_REPO 必填、WF_AGENT_PREFIX=cc- 防抢单、P3 哨兵键位预落、WF_CLAUDE_ARGS 逗号分隔、WF_VERIFY_KEYWORDS 十关键词） | `config/wf.env.example`（新增） |
| 6 | 新增守卫测试（假执行器替身 claude，记录调用 + 按场景 commit/fail7，覆盖 6 分支：running 拒派=3 且执行器零调用 / 父卡未完成=3 / 真产出=0 done 摘要含 produced / 零产出=1 blocked 评论含两次快照 / 验证型零产出=0 done / worker exit=7 透传码 blocked）；一次性看板自建自清 | `tests/test_dispatch_guards.sh`（新增） |
| 7 | 测试集注册守卫用例为第 10 段（标题编号统一为 [x/10]），断言 6 分支全过 | `tests/run_tests.sh` |
| 8 | 目录表补 3 个新脚本 + wf.env.example | `README.md` |

未做项（后续卡）：P3 哨兵（消费 WF_MAX_CONCURRENT/WF_POLL_SECONDS 等键位）、P4 `claude --agent` 原生角色加载
（当前 `~/.claude/agents/` 还没有 `cc-*` profile，角色名仍只写 TASK.md 文本）。

---

## v4.5.3（2026-10-15）— 桥任务完成唤醒链路（B 方案：事件驱动续接）

实测断链根因：`claude-bg` 只在启动时写 status.json=running，claude 完成后**没有任何代码写终态**
→ 哨兵/巡检按状态判活永远等不到 → 对话内轮询硬等又被 terminal 超时（420s/次）与 turn 生命周期
拖死，"Claude Code 完成了但后续工作不继续"。修复为三段唤醒链：**收割器写终态 → watchdog 报
BRIDGE_LANE_DONE → 巡检 agent 验收闭环 + ack**。

| # | 改动 | 落点 |
|---|------|------|
| 1 | `claude-bg` 经 `<task_dir>/run.sh` 收割器包装：claude 无论成败退出必写 `completed/failed` + exit_code + finished_at 进 status.json；status.pid 改记收割器 PID，判活与终态两信号一致 | `scripts/agent-bridge.sh` |
| 2 | watchdog 对未确认桥任务终态报 `BRIDGE_LANE_DONE <task_id> <status>`（ack 文件去重，处置完 `touch ack` 清信号，避免每轮重复唤醒） | `scripts/kanban-watchdog.py` |
| 3 | §2 新增 DONE 信号处置 SOP（反查卡→§4 闭环→complete/block→**必须写 ack**）；§4 补"收口前核验产出已入库"（`git log -- <文件>` 反查 + `merge-base --is-ancestor` 核推送，T-KSDEF-1 实测坑）；存量无 run.sh 任务按 DEAD 补终态 | `skills/kanban-executor/SKILL.md` |
| 4 | 模式 2 补收割器说明与 HERMES_HOME/scripts 副本同步警告（cron monitor 脚本读 `HERMES_HOME/scripts/`，改项目副本不同步会静默失效） | `skills/agent-bridge/SKILL.md` |

已实测：假 claude 全链路（收割器写 completed → watchdog 报 DONE → 部分 ack 只报剩余 → 全 ack 消失）通过；
建投项目部署副本已同步（md5 一致）并挂回巡检 cron。

---

## v4.5.2（2026-10-13）— 吸收三份外部文档的有效增量（复用调研 / TDD 闸门 / Git 口径）

来源：三份 ruoyi-claude 项目 wiki 概念页（coding-style / development-workflow / git-workflow）与本仓资产逐条比对，
确认绝大部分是本仓编码规范与角色库的**子集或项目专属内容**（不入库），只吸收三处真缺口。

> 版本号说明：本机先写为 v4.5.1，合并 origin/main 时发现远端已用 v4.5.1（部署校验假红修复），
> 故本笔顺延为 v4.5.2；两笔内容互不重叠，均已入库。

| # | 改动 | 落点 |
|---|------|------|
| 1 | **实现前复用调研升为前置硬约束**：新增 §7.4（仓库内已有 → 已有依赖 → 成熟库 → 自研+理由），并挂进 S3 准出与 DD 架构选型栏；无网络项目降级走前两步 | `Hermes_制度层.md` §1.1/§7.4、`skills/project-workflow/SKILL.md` S3 |
| 2 | **TDD 由"可选角色"改为按项目可开闸门**：有测试设施的项目，完成标准须含一条"先写的、能失败的测试"；无测试设施降级为可复现验证命令（编译/只读实测 SQL/反射核验）并写降级理由 | `Hermes_制度层.md` §2、`Hermes模板库/04_任务卡模板.md` §三 |
| 3 | **提交消息三条硬规则**：引用任务卡号 `T-NNN`、正文写"为什么"、标题单行 ≤72 ASCII 宽度（中文按 2 折算） | `Hermes模板库/编码规范_跨语言.md` §7.1.1 |
| 4 | **修分支策略空指针**：原文"推荐 GitHub Flow…详见各语言规范"指向不存在的章节；改写为本 kit 真实模型（worktree 一卡一分支 → 验收通过直接 merge/cherry-pick，**不使用 PR 工作流**；禁止 rebase 已推送分支/force push），并明确验收 diff 口径为 `git diff <分支基点>...HEAD` | `Hermes模板库/编码规范_跨语言.md` §7.2 |
| 5 | **交付验证报告 7 项 → 8 项**：新增"改动范围核对"（分支基点 diff 与 files_scope/changed_files 逐项一致） | `Hermes模板库/07_交付验证报告模板.md` |
| 6 | **任务卡新增"复用结论"栏**（纯改配置/文案可写"不适用"）+ 完成标准补"可失败验证"条目 | `Hermes模板库/04_任务卡模板.md` |

未吸收清单（判定为重复或项目专属）：不可变性/文件组织/错误处理/输入验证/质量清单/提交类型表（均为本仓编码规范子集）、
PR 工作流五步（本 kit 无 PR 模型，等价能力在 07 交付验证报告）、Feign/mall-api、MySQL MCP、`version.md`（已被 `10_版本记录模板.md` 覆盖）、7 个子 agent 分工（本仓 16 角色库已覆盖）。

## v4.5.1（2026-10-13）— 部署校验假红修复

| 分项 | 改动 | 落点 |
|------|------|------|
| 引用检查排除部署产物 | `iter_repo_files()` 跳过 `.deploy-backup/`（旧快照非活资产）与 `.test-tmp/`（测试工作区）；建投项目 8 处备份误报清零，已同步 5 个部署项目 | `scripts/check-references.py` |
| 脚本计数期望 5→6（kit 外联动） | Hermes home 技能 workflow-kit-deploy（仓库外资产）的 deploy-workflow-kit.sh verify 期望值与其 SKILL.md 两处计数文档改 6（v4.4 加 kanban-watchdog.py 时漏更） | Hermes home 技能目录（kit 仓库外） |

---

## v4.5（2026-10-13）— 并入《Hermes 看板机制说明书》+ 操作层按本机源码纠偏

### 改动

| # | 分项 | 改动 | 落点 |
|---|------|------|------|
| 1 | 机制事实源落户 | 说明书全文（零绝对路径版）+ 追加"勘误与补录"节 E1–E5（对照本机 Hermes 源码逐条核实：附录 A 命令不全、§8.4 已记 `skipped_nonspawnable` 事件非纯静默、配置键全表缺漏、`default_assignee` 兜底派出行为、`list --json` 无 claim_lock） | `skills/kanban-executor/references/kanban机制说明书.md` |
| 2 | kanban-executor v1.0→v1.1 | 清除假命令（`reopen`→promote/unblock/reclaim、`runs --active`→`runs <卡号>`）；废除"悬空卡 assign default"（会触发网关抢单，与外部执行者铁律相反）改为补派 lane 名；全部示例补 `--board`；block 强制 `--kind`；状态词对齐 9 态真名+口径对照表；新增铁律区、孤儿锁 SOP、13.3 哨兵自承担清单（promote/reclaim/落盘计数） | `skills/kanban-executor/SKILL.md` |
| 3 | 防抢单配置联动 | 本机 `kanban.default_assignee` 置空（原值 `default`：无 assignee 的 ready 卡会被网关自动兜底派出，与"代码只由 Claude Code 写"冲突）；操作规程侧由 executor 铁律 2 + 建卡核对 assignee 双保险 | 本机 config（文档侧记录于说明书勘误 E4） |
| 4 | watchdog 纠偏增强 | 状态判据对齐真名（去掉永不出现的 `in_progress` 分支，信号名保留）；新增第三路信号 `DIAG_ACTIVE <卡> <kind>`（`diagnostics --json`，零 SQL 检出 stranded_in_ready/孤儿锁类），实测 tunnel-management 板输出正确 | `scripts/kanban-watchdog.py` |
| 5 | 模板 08 schema 口径 | 头部声明补：真实列以 `PRAGMA table_info(tasks)` 为准（39 列、无 depends_on/updated_at）、9 态真名与口径词对照、assignee=路由键语义、命令必带 `--board` | `Hermes模板库/08_看板卡片模板.md` |
| 6 | 流程入口对齐 | S4 建卡补 `--board`+lane assignee 要求与 link 串行表达；S5 状态机标注口径词↔真名；S7 标注 done≠archived | `skills/project-workflow/SKILL.md` |
| 7 | 指针接线 | 制度层"任务看板"行、README 目录表与关键约定表加机制事实源指针（只引路径不搬正文，守单一事实源） | `Hermes_制度层.md` `README.md` |

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
