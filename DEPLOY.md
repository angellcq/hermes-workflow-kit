# 部署指南（Deployment Guide）

> 把 Hermes Workflow Kit 部署到**目标项目的 `.hermes/`**（项目级工作流，加载项目后生效）。

## 一、部署目标

套件内容只进目标项目根目录的 `.hermes/`，**不部署到 Hermes 全局 home**。打开该项目、加载 `.hermes/` 后工作流才生效。

设：
- `SRC` = 套件本地缓存（`F:\Gitee.com\hermes-workflow-kit`，GitHub `git@github.com:angellcq/hermes-workflow-kit.git` 的克隆）
- `PROJ` = 目标项目根（如 `F:\Gitee.com\jt-dream-database`）

## 二、部署映射

| 套件内容 | 项目位置 |
|----------|----------|
| `Hermes_制度层.md` | `.hermes/Hermes制度层.md`（去下划线） |
| `Hermes模板库/` | `.hermes/Hermes模板库/` |
| `skills/` | `.hermes/skills/` |
| `config/` | `.hermes/config/` |
| `scripts/` | `.hermes/scripts/` |
| `通用角色库/` | `.hermes/通用角色库/` |
| `通用角色库说明.md` | `.hermes/通用角色库说明.md` |
| `CHANGELOG.md` | `.hermes/CHANGELOG.md` |
| `USAGE.md` | `.hermes/USAGE.md` |

> 不部署（套件自身元文档/自测）：`README.md`、`DEPLOY.md`、`LICENSE`、`tests/`、`.git*`。

## 三、部署步骤

```bash
SRC="F:/Gitee.com/hermes-workflow-kit"
PROJ="F:/Gitee.com/<你的项目>"

# ═══ 1. 建 .hermes 目录 ═══
mkdir -p "$PROJ/.hermes"

# ═══ 2. 复制单文件（制度层去下划线重命名） ═══
cp "$SRC/Hermes_制度层.md" "$PROJ/.hermes/Hermes制度层.md"
cp "$SRC/通用角色库说明.md" "$PROJ/.hermes/"
cp "$SRC/CHANGELOG.md" "$PROJ/.hermes/"
cp "$SRC/USAGE.md" "$PROJ/.hermes/"

# ═══ 3. 复制目录 ═══
cp -r "$SRC/Hermes模板库" "$PROJ/.hermes/"
cp -r "$SRC/skills" "$PROJ/.hermes/"
cp -r "$SRC/config" "$PROJ/.hermes/"
cp -r "$SRC/scripts" "$PROJ/.hermes/"
cp -r "$SRC/通用角色库" "$PROJ/.hermes/"
```

## 四、接线入口：项目根 AGENTS.md 追加 §7

- 项目**已有** `AGENTS.md` → 只追加 §7 入口，不动原文。追加前 `grep -n "Hermes 开发工作流" "$PROJ/AGENTS.md"` 防重复。
- 项目**无** `AGENTS.md` → 新建，内容即下方 §7 文本。

§7 入口文本（原样追加）：

```
## 7. Hermes 开发工作流（按需启用）

本项目配套了结构化交付工作流（七阶段：澄清→PRD→HLD/DD→拆卡派发→跟踪→验证→归档），资产在 `.hermes/`：

- **制度层**：`.hermes/Hermes制度层.md`（人格内核、七阶段流程、准入准出、派发规则、协商触发、编码委派规范）
- **模板库**：`.hermes/Hermes模板库/`（01 PRD / 02 HLD / 03 DD / 04 任务卡 / 05 会议纪要 / 06 进度报告 / 07 交付验证报告 / 08 看板卡片）

**适用判定**：查询、单点修复、改配置等快任务直接执行，不走流程；单模块功能裁剪走（澄清→任务卡→执行→验证）；仅多任务交付、需求有歧义或需合规追溯时才启用完整流程——启用时先读 `.hermes/Hermes制度层.md`，产出结构化文档前先读对应模板全文。用户说"走全流程"时强制启用，说"直接改"时强制跳过。

**项目红线优先**：本文件已有章节的技术事实与本节工作流冲突时，技术事实优先。
```

## 五、忽略 .hermes/（个人工具不进项目 git）

`.hermes/` 是个人工具，不进项目 git 版本库。若 `PROJ/.git` 存在：

```bash
grep -q '^/.hermes/' "$PROJ/.gitignore" 2>/dev/null || echo '/.hermes/' >> "$PROJ/.gitignore"
```

（`.gitignore` 不存在时上述命令会自动新建。）

## 六、文件总览（部署后）

```
PROJ/
├── AGENTS.md                    ← 项目技术地图 + §7 工作流入口
└── .hermes/
    ├── Hermes制度层.md          ← 制度层（人格内核 + 七阶段流程 + 委派规范 + 军规）
    ├── Hermes模板库/            ← 01-10 文档模板 + 编码规范_跨语言.md
    ├── skills/                  ← project-workflow / kanban-executor / codegraph-review / agent-bridge / autonomous-delivery / cross-language
    ├── config/                  ← projects.yaml / languages.yaml / stale-patterns.txt
    ├── scripts/                 ← agent-bridge.sh / pipeline.py / check-references.py 等
    ├── 通用角色库/              ← 16 个跨项目通用角色 .md
    ├── 通用角色库说明.md
    ├── CHANGELOG.md
    └── USAGE.md
```

## 七、更新（已有部署时）

套件更新后执行"更新工作流"（Hermes 技能 `hermes-workflow-update`），或手动：

1. 拉最新套件：`git -C "$SRC" pull --ff-only`
2. 目录级镜像（清空重建，源删了目标也删）：`Hermes模板库/` `skills/` `config/` `scripts/` `通用角色库/` 五个目录 `rm -rf` 后重新 `cp -r`
3. 单文件覆盖：`Hermes_制度层.md`（去下划线）、`通用角色库说明.md`、`CHANGELOG.md`、`USAGE.md`
4. 项目 `.hermes/` 根下项目独有文件（任务卡、追踪矩阵等）保留，不误删。
