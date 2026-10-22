# Hermes Workflow Kit

Hermes 多 Agent 开发工作流套件（**项目级部署**）：制度层（人格内核 + 七阶段流程 + 委派规范 + 军规）+ 模板库 + 通用角色库 + 技能与脚本，覆盖从需求澄清到交付验证的全链路。

## 架构总览（项目级部署）

```
<项目根>/
├── AGENTS.md                    ← 项目技术地图 + §7 工作流入口（引用 .hermes/）
└── .hermes/
    ├── Hermes制度层.md          ← 制度层：人格内核 + 七阶段流程 + 委派规范 + 军规
    ├── Hermes模板库/            ← 01-10 文档模板 + 编码规范_跨语言.md
    ├── skills/                  ← project-workflow / kanban-executor / codegraph-review / agent-bridge / autonomous-delivery / cross-language
    ├── config/                  ← projects.yaml / languages.yaml / stale-patterns.txt
    ├── scripts/                 ← agent-bridge.sh / pipeline.py / check-references.py 等
    ├── 通用角色库/              ← 16 个跨项目通用角色 .md
    ├── 通用角色库说明.md
    └── CHANGELOG.md / USAGE.md
```

> 所有工作流资产部署进项目 `.hermes/`，加载项目后生效；套件自身元文档（README/DEPLOY/LICENSE/tests）不进项目。

## 项目级部署映射（套件 → 项目）

| 套件内容 | 项目位置 | 加载方式 |
|----------|----------|----------|
| `Hermes_制度层.md` | `.hermes/Hermes制度层.md`（去下划线） | 项目根 AGENTS.md §7 入口引用（自动注入） |
| `Hermes模板库/` | `.hermes/Hermes模板库/` | 按需引用 |
| `skills/` | `.hermes/skills/` | 自动注册（Hermes 项目级技能目录） |
| `config/` | `.hermes/config/` | 按需加载 |
| `scripts/` | `.hermes/scripts/` | 按需调用 |
| `通用角色库/` + `通用角色库说明.md` | `.hermes/通用角色库/` + `.hermes/通用角色库说明.md` | 委派引用 |
| `CHANGELOG.md` / `USAGE.md` | `.hermes/` | 存档 / 引用 |

> 与 GitHub 不一致的两点：① `Hermes_制度层.md` 部署时去掉下划线（项目已用 `Hermes制度层.md` 命名，AGENTS.md §7 引用无下划线版）；② 套件自身元文档（README/DEPLOY/LICENSE/tests/.git*）不部署进项目。

## 快速开始

```bash
# 1. 部署套件到项目 .hermes/（映射见上表）
#    详见 DEPLOY.md

# 2. 验证
bash .hermes/scripts/agent-bridge.sh roles   # 列出角色（动态扫描）

# 3. 使用（三种模式：轻量 / 严谨 / 自动）
#    详见 USAGE.md

# 4. 运行测试集（脚本语法 / 角色加载 / pipeline 冒烟 / 引用完整性）
bash tests/run_tests.sh
```

## 目录说明

| 路径 | 内容 | 事实源职责 |
|------|------|-----------|
| `Hermes_制度层.md` | 制度层：人格内核（价值观/沟通纪律/边界红线/铁律）+ 七阶段流程 + 委派规范 + 军规 | 人格内核、流程与协议唯一源 |
| `Hermes模板库/` | 01-10 文档模板 + 编码规范_跨语言.md | 编码规范唯一源 |
| `通用角色库/` + `通用角色库说明.md` | 16 角色定义与清单 | **角色清单唯一源**（agent-bridge.sh 动态扫描自动同步） |
| `skills/` | project-workflow / kanban-executor / codegraph-review / agent-bridge / autonomous-delivery / cross-language / hermes-workflow-deploy / hermes-workflow-update | 技能入口 |
| `skills/hermes-workflow-deploy/` | 换机/新项目部署 runbook（bootstrap 探测 → 六步部署 → 验收四件套 → 回滚） | 部署技能入口 |
| `skills/hermes-workflow-update/` | 已部署项目的日常更新（镜像同步 + 显式清理陈旧文件 + 更新后接线自检） | 更新技能入口 |
| `skills/kanban-executor/references/kanban机制说明书.md` | Hermes 看板底层机制（9 态状态机、dispatcher、锁/TTL、熔断回收、排障 SQL）+ 本机源码核实勘误 | **看板机制唯一事实源** |
| `scripts/` | agent-bridge.sh / dispatch-lane.sh / card-sentinel.py / sentinel_tick.py / card_check.py / wf_common.py / pipeline.py / check-references.py 等 | 可执行工具 |
| `scripts/card-sentinel.py` | 哨兵本体：定时扫板，把 `cc-` 前缀 ready 卡交给 `dispatch-lane.sh` 派发（promote/reclaim/并发熔断都在这） | cc- 卡唯一派单者 |
| `scripts/dispatch-lane.sh` | 派单器：claim→执行→收尾全链路，六道守卫 + 三态产出校验；按 assignee 真加载 `cc-*` 角色（`~/.claude/agents/<name>.md` 存在才传 `--agent`）+ 缺省 `--permission-mode acceptEdits`（`WF_CLAUDE_AGENT_ENABLE`/`WF_CLAUDE_AGENTS_DIR`/`WF_CLAUDE_PERMISSION_MODE` 可配） | lane 派单唯一入口 |
| `scripts/sentinel_tick.py` | 哨兵 tick 入口：跑一轮哨兵扫描并 touch `logs/sentinel_state.json`（watchdog 按其 mtime 判哨兵僵死） | 哨兵心跳落盘 |
| `scripts/install-claude-agents.sh` | 把 `通用角色库/*.md` 装成 CC subagent 到 `~/.claude/agents/cc-*.md`（幂等、`--dry-run`/`--dir`/`--prefix`/`--only`，改写 frontmatter `name` 使其与文件名一致） | 角色原生加载（`claude -p --agent`，派单器按存在性自动接线） |
| `config/` | projects.yaml / languages.yaml / stale-patterns.txt / wf.env.example | **项目注册表与语言清单唯一源**（wf.env.example=派单器配置样例） |
| `tests/` | 最小测试集（run_tests.sh + test_pipeline.py） | 回归防线 |
| `DEPLOY.md` | 部署 SOP | — |
| `USAGE.md` | 三种使用模式 | — |
| `CHANGELOG.md` | 版本变更账本 | 版本记录唯一源 |

## 关键约定（单一事实源）

| 信息 | 唯一源 | 其他位置 |
|------|--------|---------|
| 人格内核 / 行为准则 | `Hermes_制度层.md` §九 | 原 `Hermes_主人格.md` 已合并进制度层 |
| 委派规范 / 失败兜底 | `Hermes_制度层.md` §六 | SKILL.md 引用 |
| 角色清单 | `通用角色库说明.md` §二 + 角色 .md | agent-bridge.sh 运行时扫描 |
| 编码规范（跨语言） | `Hermes模板库/编码规范_跨语言.md` | 角色文件引用 |
| 项目注册表 | `config/projects.yaml` | pipeline.py 运行时加载 |
| 语言清单 | `config/languages.yaml` | cross-language.sh 运行时加载 |
| 版本记录 | `CHANGELOG.md` | 各文件不再附版本小表 |
| 看板底层机制 | `skills/kanban-executor/references/kanban机制说明书.md` | executor/模板 08 引用 |

### 哨兵部署（cron 推荐，示例，勿照抄后忘改 `<repo>`）

```bash
hermes cron add "cd <repo> && python scripts/sentinel_tick.py" --every 5m
```

哨兵每 5 分钟扫一次板派发 `cc-` 卡；watchdog（`scripts/kanban-watchdog.py`）按
`logs/sentinel_state.json` 的 mtime 判哨兵僵死（超 900 秒报 `SENTINEL_DEAD`）。

## 许可

见 [LICENSE](LICENSE)。
