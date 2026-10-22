---
name: hermes-workflow-deploy
description: "Use when user says 部署工作流/装流程/换机部署 to a project."
version: 2.0.0
platforms: [windows, linux, macos]
---

# Hermes 工作流套件部署 Runbook（v5.0）

把 Hermes workflow kit 部署到目标机器/项目：铺 `.hermes/`、装 CC agent 角色、接看板与哨兵。
本文是 agent 按命令干活的 runbook——**先给命令，再给解释**；套件结构与部署映射的细节源是仓库根
`DEPLOY.md`（「二、部署映射」「三、部署步骤」），冲突时以它为准。日常更新（套件已有部署、要拉新版）
见 `hermes-workflow-update` 技能。

## §0 一条命令起步

```bash
# bootstrap-machine.sh 在仓库的 scripts/ 目录下
K=<kit根>/scripts
bash "$K"/bootstrap-machine.sh --project <项目根> --board <板名>        # 只探测，打印 OK/WARN/FAIL
bash "$K"/bootstrap-machine.sh --project <项目根> --board <板名> --apply  # 落地
```

先跑不带 `--apply` 的探测版，然后**按 FAIL 从上到下修**，每个 FAIL 一条可粘贴修法：

| FAIL | 修法 |
|---|---|
| claude 版本过低 | 安装/升级 Claude Code 到 ≥ 2.1.300（见 §1 第 1 条） |
| `~/.claude/agents/` 角色缺失 | `cd <kit>/通用角色库 && cp cc-*.md ~/.claude/agents/`（见 §2 第 2 步） |
| `wf.env` 缺失/字段缺 | 按 §2 第 5 步写 `wf.env` |
| 看板不存在或 slug 不对 | 按 §2 第 4 步建板，slug 必须等于 `WF_BOARD` |
| 哨兵 cron 缺 | `--apply` 后加 `--with-cron`（见 §2 第 6 步） |

## §1 v5.0 五条硬事实（写错就装不成，逐条给验证命令）

1. **`claude --version` ≥ 2.1.300**，否则 `claude --agent` 不认子代理。验证：`claude --version`，低于阈值先升级再继续，装了角色也白装。
2. **`~/.claude/agents/` 里应有 11 个 `cc-*.md`**（不是 16——5 个 C 级角色已移入 `deprecated/`，不再装成 agent）。
   验证：`ls ~/.claude/agents/cc-*.md | wc -l`，必须等于 **11**；多出来的顶层副本是陈旧文件，删掉。
3. **`hermes cron create` 的 schedule 是位置参数**（没有 `--every` 这种 flag），且 `--script` **只认
   `$HERMES_HOME/scripts/` 下的文件名** → 哨兵脚本必须先拷进 `$HERMES_HOME/scripts/`，再用包装壳挂 cron。
   写法：`hermes cron create sentinel-<板> "every 15m" --script sentinel-wrapper.sh ...`（`every 15m` 直接跟在名字后面）。
4. **全局 watchdog 看的是 `$HERMES_HOME/logs/sentinel_state.json`，哨兵状态写在项目 `logs/`**
   → 包装壳必须在 tick 成功后补 touch 一份全局心跳，否则每轮误报 `SENTINEL_DEAD no-state`。
   验证：`ls "$HERMES_HOME/logs/sentinel_state.json"` 存在且 mtime 在最近一个周期内。
5. **给原生程序（git / python / hermes.exe）的路径必须写 `C:/x/y`**，`/c/x/y` 会报
   `cannot change to '/c/...'`。bash 内建（ls/cp/cd）两者都行；凡是传给原生 exe 的参数，一律盘符正斜杠。

## §2 六步部署顺序（每步：命令 → 期望输出 → 失败症状 → 修法）

1. **铺 `.hermes/`**（tar 镜像，含 `deprecated/` 清理）：
   ```bash
   bash skills/hermes-workflow-update/scripts/deploy-one-project.sh <项目根> --prune
   ```
   期望：`目录镜像完成`、校验段两列全 0、`角色=11 废弃=5`。失败症状：`✗ ... 不存在`（路径盘符错，见 §1 第 5 条）；
   角色数不是 11 → 顶层残留旧副本没删干净，用 `--prune` 重跑或按 `diff -rq` 的 `Only in` 逐个 `rm -f`（**逐文件，不整目录 rm -rf**——整目录删会被安全层拦）。
2. **装角色**（CC agent，不是 Hermes profile）：
   ```bash
   cd <kit>/通用角色库 && cp cc-*.md ~/.claude/agents/
   ls ~/.claude/agents/cc-*.md | wc -l   # 期望 11
   ```
   失败症状：`claude --agent <角色>` 报找不到 agent → 角色没装或 claude 版本 < 2.1.300（§1 第 1 条）。
3. **拷全局件**（watchdog + 技能副本，都在 `$HERMES_HOME` 下）：
   ```bash
   K=<kit根>/scripts   # 哨兵 cron 的 --script 只认 $HERMES_HOME/scripts/ 下的文件名（§1 第 3 条）
   cp "$K"/kanban-watchdog.py "$HERMES_HOME/scripts/"
   cp "$K"/sentinel-wrapper.sh "$HERMES_HOME/scripts/"
   ```
   失败症状：cron 每轮 `blocked_config` / script not found → 脚本没落在 `$HERMES_HOME/scripts/`，或路径写了 `/c/...`（§1 第 5 条）。
4. **建看板**：slug 必须等于第 5 步 `wf.env` 里的 `WF_BOARD`，两侧不一致是 `total_ready=0` 的头号真因（§4 第 1 行）。
5. **写/校 `wf.env`**：项目 `.hermes/config/wf.env`，字段与看板 slug 对齐；改完 `cat` 一遍核对。
6. **可选挂哨兵 cron**（`--with-cron` 时）：先确保包装壳在 `$HERMES_HOME/scripts/`（第 3 步），再：
   ```bash
   hermes cron create sentinel-<板> "every 15m" --script sentinel-wrapper.sh
   ```
   schedule 是位置参数；`unrecognized arguments: --every` = 写法退化了（§4）。

## §3 收尾验收四件套（缺一个都不算部署完成）

1. `bash tests/run_tests.sh` 全绿（≥25 断言）。
2. 看板 slug 与 `wf.env` 的 `WF_BOARD` 一致：`hermes kanban list` 对照 `cat <项目根>/.hermes/config/wf.env`。
3. 手动跑一次哨兵：`python "$HERMES_HOME/scripts/sentinel_tick.py" --project <项目根>`，
   然后看项目 `logs/tick.log` 出现 `rc=0 ... total_ready=N`（N ≥ 0，关键是 rc=0 且有输出）。
4. `python "$HERMES_HOME/scripts/kanban-watchdog.py" --board <板>` 输出里**没有** `SENTINEL_DEAD`。
   若有 `SENTINEL_DEAD no-state` → 哨兵没跑过或包装壳没补全局心跳（§1 第 4 条、§4 第 2 行）。

## §4 换机常见失败对照表（症状 → 真因 → 修法）

| 症状 | 真因 | 修法 |
|---|---|---|
| `total_ready=0` 永远为 0 | 板名不一致（看板 slug ≠ `WF_BOARD`）或 assignee 无 `cc-` 前缀 | 对齐 slug 与 `wf.env`；卡片的 assignee 改成 `cc-*` 角色名（`~/.claude/agents/` 里 11 个之一） |
| `SENTINEL_DEAD no-state` | 哨兵没跑过一次，或包装壳 tick 成功后没补 touch `$HERMES_HOME/logs/sentinel_state.json` 全局心跳 | 先手动跑一次 `sentinel_tick.py`（§3 第 3 条）；检查包装壳是否补了全局心跳（§1 第 4 条） |
| `claude --agent` 报错 | 角色没装进 `~/.claude/agents/`，或 claude 版本 < 2.1.300 | `cp cc-*.md ~/.claude/agents/`（§2 第 2 步）；`claude --version` 升级（§1 第 1 条） |
| `cron create` 报 `unrecognized arguments: --every` | schedule 是位置参数，不是 flag | `hermes cron create <名字> "every 15m" --script ...`，`every 15m` 直接写（§1 第 3 条） |
| `cannot change to '/c/...'` | 给原生程序传了 MSYS 路径 | 改写 `C:/x/y` 盘符正斜杠（§1 第 5 条） |

## §5 回滚

- **退回手动派发**：删项目 `<项目根>/.hermes/config/wf.env` 即可，套件其余文件无害。
- **停哨兵**：`hermes cronjob pause sentinel-<板>`（别删 job，恢复只需 unpause）。
- **全局件**：覆盖前都留了 `.bak.<时间戳>` 备份，出问题用备份还原 `$HERMES_HOME/scripts/` 与技能副本。
- **项目 `.hermes/`**：`deploy-one-project.sh` 每次跑前自动备份 `<scratch>/deploy/<项目名>-<时间>.tgz`，从那里解包还原。
