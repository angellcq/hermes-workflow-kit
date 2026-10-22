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

## 三、部署前置检查

部署前跑这四条命令，每条都有明确的判定标准：

```bash
claude --version                                   # 必须 ≥ 2.1.300（--agent 支持）
ls ~/.claude/agents/ | wc -l                       # 记录数量基线；装完再数一次应变大
echo $CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS         # 期望 1（agent teams 开关）
test -f "$PROJ/.claude/settings.json" && echo ok   # 项目级 settings 存在
```

- **`claude --version`**：低于 2.1.300 时 `--agent` 不认，角色装上也调不到。
- **`ls ~/.claude/agents/ | wc -l`**：agents 目录常被别的套件塞满（本机实测 187 个，裸名已被占），所以本套件装角色一律加前缀（默认 `cc-`，装到 `~/.claude/agents/cc-<name>.md`）。基线数字用于装完对比——应增加 11（角色库数量）。
- **`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`**：只影响 agent teams 功能，不影响 `--agent` 单 agent 加载；期望为 1 但缺失时不阻塞部署。
- **`.claude/settings.json`**：项目级 settings 缺失会导致权限模式不可控（CC 子 agent 写文件在多数权限模式下会被弹窗卡死）。

角色安装（替代已废弃的 `sync-roles-to-profiles.sh`）：

```bash
bash "$SRC/scripts/install-claude-agents.sh"          # 装到 ~/.claude/agents/cc-*.md
# 加载：claude -p --agent cc-<name>
# ⚠ 不要用 Agent 工具派发角色（写文件会被权限弹窗卡死，四种权限模式实测全失败）
```

## 四、部署步骤

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

# ═══ 4. 看板巡检 watchdog（可选，推荐；HOME 级，不是项目级）═══
# 派发后自动巡检：卡完成/超时/悬空/lane 断头 → 主动通知并处置；无变化零 token
cp "$SRC/scripts/kanban-watchdog.py" "$LOCALAPPDATA/hermes/scripts/"   # Windows（cron 要求脚本在 HERMES_HOME/scripts 下）
# Linux/macOS: cp "$SRC/scripts/kanban-watchdog.py" ~/.hermes/scripts/
# 注册 cron（monitor 模式：指纹不变不唤醒 agent；变化才跑处置 prompt；CLI 只有 --monitor-script 这个参数名）：
hermes cron create "every 15m" \
  "按 kanban-executor 规则处置 monitor 指纹 diff：CLAIM_PENDING 认领悬空 ready 卡；IN_PROGRESS_TIMEOUT 查因重派或 block；DONE_UNVERIFIED 跑验收闭环（git diff 非空+编译通过+白名单核对）后 comment+archive；BLOCKED 仅汇报；BRIDGE_LANE_DEAD/STALE 查 agent-bridge 任务目录判死因；DIAG_ACTIVE 按 diagnostics 项处置（孤儿锁 reclaim 等）。中文简报收尾。" \
  --name kanban-board-watchdog --skill kanban-executor \
  --monitor-script kanban-watchdog.py --deliver "feishu,bot-chat"

# ═══ 5. 建看板 ═══
# <slug> 必须与该项目 config/wf.env 的 WF_BOARD 完全一致——不一致的后果：
# 哨兵每轮 total_ready=0，日志看着正常但永远不派单
hermes kanban board create <slug>

# ═══ 6. 拷全局技能副本 + 哨兵接线 ═══
# kanban-executor 的全局副本必须单独拷进 HERMES_HOME（只拷项目 .hermes/ 不生效——
# cron --skill 解析的是全局技能目录）：
mkdir -p "$LOCALAPPDATA/hermes/skills/devops/"
cp -r "$SRC/skills/kanban-executor" "$LOCALAPPDATA/hermes/skills/devops/kanban-executor"
# Linux/macOS: mkdir -p ~/.hermes/skills/devops/ && cp -r "$SRC/skills/kanban-executor" ~/.hermes/skills/devops/
# 哨兵 cron（包装壳 + 心跳 touch 由 scripts/bootstrap-machine.sh --with-cron 自动生成，见下）：
#   hermes cron create "every 5m" --no-agent --name sentinel-<板> --script sentinel-<板>.sh --deliver local

# ═══ 7. 重启 Hermes 进程 ═══
# 桌面端/网关/CLI 重启
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
    ├── 通用角色库/              ← 11 个跨项目通用角色 .md
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

## 八、换机检查单（新机器从零到哨兵跑通）

按顺序 7 步，每步一条可粘贴命令 + 期望输出。前 4 步交给 `scripts/bootstrap-machine.sh`，
第 5 步必须手工建（bootstrap 不管巡检 cron）；第 7 步起由 `scripts/verify-deploy.sh`
统一验收（原第 6/7 步的手动哨兵/watchdog 核对已并入验收项 V9/V10）。

```bash
# ── 1. 拉代码 + 回归防线 ──
git clone git@github.com:angellcq/hermes-workflow-kit.git && cd hermes-workflow-kit
bash tests/run_tests.sh
# 期望：═══ 结果：≥25 通过 / 0 失败 ═══（失败逐条按提示修，别带病往下走）

# ── 2. bootstrap 探测模式（只看不改）──
bash scripts/bootstrap-machine.sh --project <项目根> --board <板>
# 期望：末尾 ══ bootstrap 完成：OK=x WARN=y FAIL=0 ══；FAIL 逐条按提示修

# ── 3. 落地（生成 wf.env、装 11 个角色、拷全局件、建看板）──
bash scripts/bootstrap-machine.sh --project <项目根> --board <板> --apply

# ── 4. 哨兵接线（生成 $HERMES_HOME/scripts/sentinel-<板>.sh 包装壳 + 建哨兵 cron）──
bash scripts/bootstrap-machine.sh --project <项目根> --board <板> --apply --with-cron

# ── 5. 手工建巡检 cron（bootstrap 不管这条，必须手建）──
hermes cron create "every 15m" \
  "按 kanban-executor 规则处置 monitor 指纹 diff：CLAIM_PENDING 认领悬空 ready 卡；IN_PROGRESS_TIMEOUT 查因重派或 block；DONE_UNVERIFIED 跑验收闭环（git diff 非空+编译通过+白名单核对）后 comment+archive；BLOCKED 仅汇报；BRIDGE_LANE_DEAD/STALE 查 agent-bridge 任务目录判死因；DIAG_ACTIVE 按 diagnostics 项处置（孤儿锁 reclaim 等）。中文简报收尾。" \
  --name kanban-board-watchdog --skill kanban-executor \
  --monitor-script kanban-watchdog.py --deliver "feishu,bot-chat"

# ── 6. 手动跑一轮哨兵，验证派单链路 ──
python "$HERMES_HOME/scripts/sentinel-<板>.sh"
# 期望：项目 logs/tick.log 出现 rc=0 dispatched=0 skipped=0 total_ready=N

# ── 7. 统一验收：V1..V10 一条命令跑完（v5.0-P9 起）──
bash scripts/verify-deploy.sh --project <项目根> --board <板>
# 期望：═══ 验收：N 通过 / 0 失败 ══（有 FAIL 退 1，每条 FAIL 带可粘贴修法）
# 首台机器可加 --smoke：追加 V11 端到端冒烟（建 [SMOKE] 卡 → tick → 断言派单链路 → 归档清理）
```

随时复查接线：`bash scripts/bootstrap-machine.sh --check`。

### 脚本不过时怎么手工查

verify-deploy.sh 逐项 FAIL 时，第 7 步各项对应的手工命令对照表：

| 验收项 | 手工命令 | 期望 |
|--------|---------|------|
| V1 仓库自检 | `bash tests/run_tests.sh` | `═══ 结果：N 通过 / 0 失败 ═══` |
| V2 接线自检 | `bash scripts/bootstrap-machine.sh --project <项目根> --board <板>` | `检查结果：OK=x WARN=y FAIL=0` |
| V3 角色已装 | `ls ~/.claude/agents/cc-*.md \| wc -l` | `11` |
| V4 全局件一致 | `md5sum "$HERMES_HOME/scripts/kanban-watchdog.py" scripts/kanban-watchdog.py`<br>`grep '^version:' "$HERMES_HOME/skills/devops/kanban-executor/SKILL.md" skills/kanban-executor/SKILL.md` | md5 相同；version 相同 |
| V5 项目资产齐 | `ls <项目根>/.hermes/` | 五目录 + `Hermes制度层.md` + `USAGE.md`；`通用角色库/*.md`=11、`deprecated/*.md`=5 |
| V6 板名一致 | `grep '^WF_BOARD=' <项目根>/.hermes/config/wf.env` | 与 `--board` 相同 |
| V7 看板存在 | `hermes kanban boards` | 输出含 `<板>` |
| V8 哨兵 cron 存在 | `hermes cron list` | 输出含 `sentinel-<板>` |
| V9 哨兵真能跑 | `bash "$HERMES_HOME/scripts/sentinel-<板>.sh"` 后 `tail -1 <项目根>/logs/tick.log` | 末行含 `rc=0` |
| V10 无死亡误报 | `python "$HERMES_HOME/scripts/kanban-watchdog.py" --board <板>` | 无 `SENTINEL_DEAD` |
| V11 冒烟（`--smoke`） | `hermes kanban --board <板> create "[SMOKE] test" --assignee cc-backend-developer` 后手动 tick 一轮 | tick.log `total_ready` ≥ 1；验完 `hermes kanban archive <id>` |
