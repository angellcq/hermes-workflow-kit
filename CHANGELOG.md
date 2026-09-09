# Changelog

> Hermes Workflow Kit 的版本变更与融合历史。`README_FUSION_HISTORY.md`（v4.0 详细变更）已废弃，所有变更在此累积。

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
