---
name: hermes-workflow-update
description: Use when 用户说「更新工作流」. 拉 GitHub 最新套件镜像同步到项目 .hermes/.
version: 1.4.0
platforms: [windows]
metadata:
  hermes:
    tags: [workflow, deploy, update, hermes-workflow-kit]
    related_skills: [hermes-workflow-deploy, project-workflow, kanban-executor, codegraph-review]
---

# Hermes 工作流更新技能（"更新工作流"）

用户说"更新工作流"，即把 GitHub 云端套件最新版拉下来，**镜像同步**到当前项目 `.hermes/`（项目级工作流，加载项目后生效）。
首次部署（新机器/新项目从零装）见 `hermes-workflow-deploy` 技能；部署映射与套件结构的细节源是仓库根 `DEPLOY.md`。

## 触发词

"更新工作流"、"同步工作流"、"刷新工作流"、"工作流更新"。

## 核心原则

1. **项目级**：所有套件内容只进当前项目 `.hermes/`，不往全局 home（SOUL.md / ~/.claude/agents/ / 全局 skills）部署。
2. **镜像同步（彻底更新）**：源（GitHub 套件）删除的文件，项目里必须同步删除，不能残留。目录级「覆盖式镜像」（先只读预检确认有没有真删除，再决定要不要清空重建），单文件「覆盖」。
3. **不误删项目独有内容**：`.hermes/` 根下项目运行时产生的文件（任务卡、追踪矩阵等）不在套件映射内，一律保留。
4. **需用户拍板的动作，无答复 = 不动**：下列四类不属于「例行部署」，`clarify` 超时/未答一律视为**未同意**，保持现状并在报告里列出「待拍板 + 我的建议」：① `git push`；② 替换全局件（`HERMES_HOME/scripts/*`、全局 skills 副本）；③ 挂能自动派单/自动跑任务的 cron（会烧 token 且改行为）；④ 删目标侧文件（`--prune`）。理由：这四类的副作用不在项目内、不可从 `.hermes/` 备份回滚。
   对应的**可自主做**的那一半：项目级镜像、单文件覆盖、项目独有行保留、校验与报告 —— 把这两类分开报，别把「需拍板」搵成「没做完」。

## 套件源（单一事实源）

**铁律：套件仓库只缓存在固定位置 `F:\Gitee.com\hermes-workflow-kit`，绝不 clone 进项目；更新 = git pull + 复制，不是 clone。**

1. 本地缓存 `F:\Gitee.com\hermes-workflow-kit`（GitHub `git@github.com:angellcq/hermes-workflow-kit.git` 克隆）：
   - 存在 → `git -C "F:/Gitee.com/hermes-workflow-kit" pull --ff-only`
   - 不存在 → `git clone git@github.com:angellcq/hermes-workflow-kit.git "F:/Gitee.com/hermes-workflow-kit"`（SSH 失败换 `https://github.com/angellcq/hermes-workflow-kit.git`，再失败走 -local）
2. 本地备份 `F:\Gitee.com\hermes-workflow-kit-local`（无远程，云端拉取失败兜底）。
3. 都没有 → 报告缺失，不凭记忆重建。

## 覆盖映射（套件 → 项目 .hermes/）

设套件根为 SRC，项目为 PROJ。

### 目录级：覆盖式镜像（源删了目标也删）

| SRC | 目标 |
|---|---|
| `Hermes模板库/` | `PROJ/.hermes/Hermes模板库/` |
| `skills/` | `PROJ/.hermes/skills/` |
| `config/` | `PROJ/.hermes/config/` |
| `scripts/` | `PROJ/.hermes/scripts/` |
| `通用角色库/` | `PROJ/.hermes/通用角色库/` |

### 单文件：覆盖

| SRC | 目标 |
|---|---|
| `Hermes_制度层.md` | `PROJ/.hermes/Hermes制度层.md`（去下划线） |
| `通用角色库说明.md` | `PROJ/.hermes/通用角色库说明.md` |
| `CHANGELOG.md` | `PROJ/.hermes/CHANGELOG.md` |
| `USAGE.md` | `PROJ/.hermes/USAGE.md` |

### 不部署（套件自身元文档/自测）

`README.md`、`DEPLOY.md`、`LICENSE`、`tests/`、`.git/`、`.gitignore`、`.gitattributes`。

## 执行步骤

> **一条命令版（推荐）**：`bash skills/hermes-workflow-update/scripts/deploy-one-project.sh <项目根> [--prune]`（本技能自带，已把下面 1-6 步连同三处硬化逻辑写完：备份 → 摘出项目独有 CHANGELOG 行 → tar 镜像 → `--prune` 删陈旧文件 → 单文件覆盖 → 独有行追加回 → 两列指标校验）。多个项目时 `for p in <项目...>; do bash skills/hermes-workflow-update/scripts/deploy-one-project.sh "$p" --prune; done`。手工步骤如下（想逐步确认时用）。

1. **拉最新**：`git -C "F:/Gitee.com/hermes-workflow-kit" pull --ff-only`。
   > 本机有未推送提交时 ff-only 必失败 —— 见「坑」里 `fetch + 两侧比对 + merge` 的顺序，**别 reset、别丢本机提交**。本地提交就是待部署的新版本时，直接跳过 pull 用本地树作为 SRC（并在报告里写明未推）。
2. **只读预检（先做，不改任何东西）**：
   ```bash
   # 目标里「套件已无」的陈旧文件（决定是否真需要删东西）
   diff -rq "PROJ/.hermes/$d" "SRC/$d" | grep "^Only in PROJ"
   # 套件本区间是否真删过文件
   git -C "$SRC" diff --diff-filter=D --name-only <旧版本tag/commit>..HEAD
   ```
   两者皆空 → 本次是**纯新增/覆盖**，不需要删任何东西（本项目历次更新皆如此：v4.4→v4.5.2 区间套件未删除任何文件）。
3. **目录级镜像（用 tar 管道，不要 rm -rf + cp -r）**：
   ```bash
   tar -c --exclude=__pycache__ -C "$SRC" Hermes模板库 skills config scripts 通用角色库 | tar -x -C "PROJ/.hermes"
   ```
   同路径解包即覆盖、源新增文件自动落地、`--exclude` 顺手挡掉源码仓的 `__pycache__`，且**天然幂等**（重跑无副作用）。
   > 为什么不用清空重建：`rm -rf "PROJ/.hermes/<目录>"` 会被 Hermes 安全层判为破坏性操作并**阻塞等用户确认**（超时即视为未同意、命令不执行）；tar 管道在实测中正常放行。若用户明确要求"删源即删目标"才需要 `rm -rf`，那时用 `clarify` 先拿到同意。

3b. **套件内移动/删除资产时，tar 不会替你删目标旧副本 —— 必须显式清理**。`tar -x` 只覆盖同名路径、新增新文件，**目标里源已经没有的文件一律留着**。
   <!-- v5.0-P8 --> v5.0 实例：5 个 C 级角色移入 `通用角色库/deprecated/` 后，目标顶层还留 5 个陈旧 md，`agent-bridge.sh roles` / agent 扫描就数出 16 个（v5.0 正确值是 **11** 个 `cc-*.md`），「角色库加载 N 个」断言直接假红。做法：`--prune` 模式按目录比对找 `Only in PROJ` 的文件逐个 `rm -f`（**逐个具体文件，不整目录 rm -rf，前者能过安全层后者会被拦**），如 `rm -f "PROJ/.hermes/通用角色库/<旧角色名>.md"`（deprecated/ 子目录里的副本保留，顶层同名副本删掉）；清理后数量断言才与源一致（`ls *.md | wc -l` = 11）。
4. **单文件覆盖**（含去下划线重命名）：
   ```bash
   cp "SRC/Hermes_制度层.md" "PROJ/.hermes/Hermes制度层.md"
   cp "SRC/通用角色库说明.md" "PROJ/.hermes/通用角色库说明.md"
   cp "SRC/CHANGELOG.md" "PROJ/.hermes/CHANGELOG.md"
   cp "SRC/USAGE.md" "PROJ/.hermes/USAGE.md"
   ```
5. **验证（两列指标，不要只看文件数）**：
   ```bash
   for d in Hermes模板库 skills config scripts 通用角色库; do
     only=$(diff -rq "$PROJ/.hermes/$d" "$SRC/$d" | grep -c "^Only in $PROJ")
     diffc=$(diff -rq "$PROJ/.hermes/$d" "$SRC/$d" | grep -c "^Files")
     echo "  $d: 目标多余=$only 内容不一致=$diffc"
   done
   # 单文件用 md5 对齐（制度层/UASGE/说明），角色数用 ls *.md | wc -l，废弃数数 deprecated/
   ```
   通过标准：**两列全 0**、单文件 md5 一致、角色数与源一致。
6. **报告**：列出本次更新版本号、新增/删除文件、与 GitHub 不一致的映射（去下划线、不部署清单），以及「项目 `.hermes/` 只是留档、全局件才是运行时生效源」这层不对称。
   <!-- v5.0-P8 --> 7. **更新后接线自检（必做收尾）**：更新完跑
   ```bash
   K=<kit根>/scripts
   bash "$K"/bootstrap-machine.sh --check --project <项目根> --board <板名>
   ```
   确认 v5.0 接线没断：角色 11 个 `cc-*.md`、`wf.env` 与看板 slug 一致、哨兵心跳正常（详见 `hermes-workflow-deploy` §0/§3）。若本次更新连带重挂哨兵 cron（需拍板类），用 `hermes cron create "every 5m" --no-agent --name sentinel-<板> --script sentinel-<板>.sh --deliver local`——schedule 是第一个位置参数，job 名走 `--name`；`--script` 只认 `$HERMES_HOME/scripts/` 下的文件名（包装壳必须先放进去），`--no-agent` 纯脚本不烧 token。输出有 FAIL → 按 deploy 技能 §0 对照表修完再收工；这一步跳过 = 「更新成功」但哨兵永远不会派单（`total_ready=0`）。

7. **全局件同步（只在用户明确同意后做，属核心原则 4 第②类）**。顺序固定，不可跳步：

   ```bash
   G="$LOCALAPPDATA/hermes"; K="F:/Gitee.com/hermes-workflow-kit"; BAK="$TMPDIR/sync-<版本>"
   D="$G"/skills"/devops"   # 全局 devops 技能目录
   # ① 先比「文件清单」，不要只比 SKILL.md 内容 —— 两侧可能是不同血缘，各有对方没有的 references
   find "$D/<技能>" -type f | sed "s|.*/<技能>/||" | sort
   find "$K/skills/<技能>"        -type f | sed "s|.*/<技能>/||" | sort
   # ② 只存在于全局副本的文件：先收进 kit（references/ + SKILL.md 加指针 + 提交推送），再同步
   # ③ 双向备份：整个旧技能目录 + 旧脚本
   cp -r "$D/<技能>" "$BAK/<技能>-<旧版本>"; cp "$G/scripts/<脚本>.py" "$BAK/<脚本>.py.old"
   # ④ 覆盖后双向核对
   md5sum "$G/scripts/<脚本>.py" "$K/scripts/<脚本>.py" | cut -c1-8   # 必须相同
   grep -m1 '^version:' "$D/<技能>/SKILL.md"
   ```

   **为什么必须先比文件清单**：全局副本被历次局部同步改成了另一支血缘（同一技能可能是 1.0.0 + A.md，kit 是 1.1.0 + B.md），直接 `cp` 会让只活在全局副本里的那份参考文档变成孤儿文件、下次任何覆盖即永久丢失。处置是「先把它收进版本库，再同步」—— 收进 kit 时要加指针，否则将来仍无人读。

   **冒烟必须双面**：老信号仍在 + 新信号出现。实测 `python "C:/<HERMES_HOME>/scripts/<脚本>.py" --board <板>`，至少两块板各跑一次；只验新信号等于没验（老版本升级最常见的事故是新能力上了、老能力哑了）。

   **同步后立即清场**：`done` 卡若指向已删除的 workspace（worktree 清理后），会每轮刷 `DONE_UNVERIFIED`，把 `SENTINEL_DEAD`/`ASSIGNEE_DRIFT` 这类真信号淹没 —— 验收过的卡直接 `archive`，处置规则见 `kanban-executor` §4「归档消音」。

   cron 的 `prompt` 是内联文本，不随技能更新；若 job 已绑定技能且技能里写明了新信号处置，可以不改 cron，但**必须在报告里点明这一层**（用户会问「新信号怎么没进巡检口径」）。

## 坑

- **`rm -rf` 会被安全层拦住**：批量 `rm -rf PROJ/.hermes/<映射目录>` 触发破坏性操作确认，超时 5 分钟即"未获同意"（命令根本没跑）。镜像用上面的 tar 管道，不要用清空重建。
- **备份要加 `--force-local`**：MSYS/git-bash 下 `tar -czf "C:\...\x.tgz"` 会把 `C:` 当远程主机名报 `Cannot connect to C: resolve failed`；用 `tar --force-local -czf` 或写成 `$LOCALAPPDATA/Temp/...` 正斜杠路径。更新前先备份 `PROJ/.hermes` 是好习惯（本次 8 个项目共 ~2.4MB）。
- **非 git 项目**：跳过 .gitignore 追加步骤（1688 项目即如此），报告里注明"非 git 仓、无需忽略"即可，不算遗漏。
- **缓存仓不是只读的：`pull --ff-only` 会因本机未推送提交失败**。用户说「获取最新代码」时，缓存仓 `F:\Gitee.com\hermes-workflow-kit` 常自带未推送的本地提交（本机改套件后忘了 push）。顺序：`git fetch origin` → `git log --oneline origin/main..HEAD`（本机 ahead）与 `HEAD..origin/main`（将进来）各看一遍 → 两侧都非空即已分叉，**用 `git merge origin/main --no-edit`，不要 ff-only、不要 reset、不要丢弃本机提交**。
- **冲突必然出现在两侧都改过的同一批文档**（CHANGELOG / README / DEPLOY / skills 下的 SKILL.md），逐个 `git diff HEAD...origin/main -- <file>` 看清远端到底改了什么再定口径，别无脑取一侧。既定口径：**架构取向取本机**（v4.4 起套件已项目级部署化：`$SRC`/`$PROJ/.hermes/`），**新内容取远端**（看板机制说明书、watchdog 等新能力），CHANGELOG 两版条目都保留、按版本倒序排。
- **合并后核对内部引用是否因重新编号而失效**：本机把 DEPLOY.md 的步骤重编号后，远端留下的 `详见 DEPLOY.md §7` 之类引用会指错地方；`grep -rn 'DEPLOY.md §\|§[0-9]' skills/*/SKILL.md` 逐个改成小节名（如「DEPLOY.md『三、部署步骤』第 4 步」）。
- **改完先跑 `bash tests/run_tests.sh`**（合并可能吞掉本地语义）；套件自带测试用例里 `cmd | grep -q` 在输出超管道缓冲（MSYS 实测约 4KB）时 grep 提前退出、上游收 SIGPIPE，会被误报成用例失败——写测试要先 `VAR=$(cmd)` 捕获再 `echo "$VAR" | grep -q`。
- **git 路径**：git/rsync 等原生 Windows 程序不认 `/f/...`（MSYS 不转换），必须写 `F:/Gitee.com/...`；bash 内建（ls/cp/cd/rm）两者都行。
- **中文路径**：git-bash 下 `cp -r`/`tar` 对中文目录正常，双引号包住即可。
- **保留映射目录内的项目独有文件**：更新前先用 `diff -rq` 看过一遍（见步骤 2）；只有确认有项目独有内容时才需要迁出，且**绝不动 `.hermes/` 根下的任务卡/`tasks/`/`tools/`/`AGENTS.md`**（不在映射内）。
- **主人格已合并**：`Hermes_主人格.md` 已从套件删除，其内容（价值观/沟通纪律/边界红线/铁律）已并入 `Hermes_制度层.md` §九，本技能不再处理主人格。
- **项目 `.hermes/skills/` 不是技能生效源（2026-10 实测分叉）**：`config.yaml` 里 `skills.external_dirs: []`，agent 与 cron 加载的是**全局 profile 副本**（如 `~/AppData/Local/hermes/skills/devops/kanban-executor/`）。项目副本可能远新于全局（实测 hljjt 项目 kanban-executor v1.1.0 vs 全局 v1.0.0，差 362 行；project-workflow 同样落后）。**同步项目 `.hermes/` 只等于留档，运行时文本不变**——报告里必须点明这层不对称，并让用户定口径（既定约定是资产只进项目、不往全局部署）。
- **cron `monitor_script` 读 `HERMES_HOME/scripts/`**：项目 `.hermes/scripts/kanban-watchdog.py` 与 `~/AppData/Local/hermes/scripts/` 同名副本必须 md5 一致才算生效（`hermes cron list` 看不到脚本路径，要读 `cron/jobs.json` 的 `monitor_script` 字段）。另 cron 的 `prompt` 是内联文本、不含指纹信号全集，套件新增信号（如 v4.5.3 的 `BRIDGE_LANE_DONE`）不会自动进巡检口径，需单独更新 cron。
- **`CHANGELOG.md` 常被项目追加本地记录**：映射表写「覆盖」但**直接 `cp` 会丢项目记录**。判定方式用**行集合差**，不要用区间 diff（新版在头部插入两节，区间 diff 会误报几十行差异）：
  ```bash
  comm -13 <(sort -u "$SRC/CHANGELOG.md") <(sort -u "$PROJ/.hermes/CHANGELOG.md")   # 项目独有行
  ```
  有独有行时：覆盖前先存下来，覆盖后追加回文件末尾（加一行 `## 项目局部记录（部署时保留）` 小标题，避免被误读成套件条目），并按行集合复验「项目独有行数」与存储前一致。
- **盘符写错会让 tar 静默失败/建空目录**：本机同时存在 `D:/kkgit.yyrd.com/...` 与一个旧的 `F:/kkgit.yyrd.com/...`，路径写错时 tar 报错被 `2>/dev/null` 吞掉或建出空目录，要到校验阶段（`find ... | wc -l` = 0）才暴露。规矩：脚本第一步 `test -d "$PROJ/.hermes" || exit 2`，并在报告里写清实际部署的项目路径。
- **下划线映射**：套件 `Hermes_制度层.md` 项目里去下划线，因项目已有此命名且 AGENTS.md §7 引用 `.hermes/Hermes制度层.md`。若用户改 GitHub 统一命名，需同步改此处映射与 AGENTS.md §7 引用。
- **多项目批量更新**：一次更多个项目时，逐项目备份（`tar --force-local -czf`）→ tar 管道镜像 → 逐项目 `diff -rq` 校验 → 汇总表输出。校验通过标准：映射内文件与源**逐字节一致**、文件数只增不减（增 = 新能力，如 v4.5 引入的 `scripts/kanban-watchdog.py` 与 kanban-executor 下的看板机制说明书）。
- <!-- v5.0-P8 --> **原生程序路径用盘符正斜杠**：给 git/python/hermes.exe 传参必须 `C:/x/y`，`/c/x/y` 会 `cannot change to`；详见 `hermes-workflow-deploy` §1 第 5 条。
- <!-- v5.0-P8 --> **本技能 `scripts/` 目录**：`deploy-one-project.sh` 支持环境变量 `SRC` 覆盖套件源路径（缺省 `F:/Gitee.com/hermes-workflow-kit`），无其他硬编码本机路径；换机时 `SRC=<新路径> bash deploy-one-project.sh ...` 即可。
