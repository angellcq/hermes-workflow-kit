# Hermes 人格与工作流 — 融合版 v4.0（跨项目无特定语言）

> 日期: 2026-09-08 ｜ 融合来源:
> - **v3.0** = 本仓库原版（七阶段状态机 + 追踪矩阵 + 建投专属规范）
> - **自动化迁移手册** = `D:\BaiduNetdiskDownload\hermes+claude code自动化工作流`（三流水线 + 32 角色库 + pipeline.py + agent-bridge.sh）
>
> 融合目标：**跨项目、无特定开发语言**，把 v3.0 的严谨流程与迁移手册的端到端自动化合并为一套通用可移植工作流。
> 融合原则：**严守 v3.0 的流程骨架（七阶段、追踪矩阵、协商分级），叠加迁移手册的自动化能力（pipeline、agent-bridge、跨角色桥接），去掉建投专属红线**。

---

## 一、本次融合的核心思路

| 维度 | 处理策略 |
|------|---------|
| **场景定位** | 从「建投系 Java 微服务二次开发」扩展到「跨项目通用（任意语言/任意规模）」 |
| **流程骨架** | v3.0 七阶段状态机保留为基座，作为 Tier 2 完整交付的入口 |
| **自动化能力** | 把迁移手册的 pipeline.py / agent-bridge.sh / 桌面 Kanban 引入为"可选增强" |
| **角色库** | 32 个建投专属角色 → 16 个跨项目通用角色（覆盖前后端/全栈/DBA/PM/审查/构建） |
| **编码规范** | 替换建投专属红线（白名单/禁 MyBatis 等）为通用最佳实践（不可变/小文件/TDD/80% 覆盖） |
| **跨语言** | 引入 `cross-language` 技能，按语言特性（强类型/动态/脚本/编译/解释）分发不同规范 |

---

## 二、模板与技能选型结论

### 2.1 模板库

| 编号 | 模板 | 来源 | 状态 |
|------|------|------|------|
| 00 | 模板索引与使用说明 | v3.0 | ✅ 保留并扩充 |
| 01 | PRD 需求文档模板 | v3.0 | ✅ 保留 |
| 02 | HLD 概要设计模板 | v3.0 | ✅ 保留 |
| 03 | DD 详细设计模板 | v3.0 | ✅ 保留 |
| 04 | 任务卡模板 | v3.0 | ✅ 保留 |
| 05 | 会议纪要模板 | v3.0 | ✅ 保留 |
| 06 | 进度报告模板 | v3.0 | ✅ 保留 |
| 07 | 交付验证报告模板 | v3.0 | ✅ 保留 |
| 08 | 看板卡片模板 | v3.0 | ✅ 保留 |
| **09** | **移交文档模板（HANDOFF）** | **迁移手册** | 🆕 新增 |
| **10** | **版本记录模板（version.md）** | **迁移手册 + v3.0 融合** | 🆕 新增 |
| **11** | **跨语言适配清单** | **新增** | 🆕 新增 |

### 2.2 技能库（融合后 6 个技能，分工明确）

| 技能 | 角色定位 | 来源 |
|------|---------|------|
| `project-workflow` | 七阶段流程入口（Tier 2 SOP） | v3.0 保留 |
| `kanban-executor` | 任务生命周期自动化（认领/心跳/回收/验证闭环） | v3.0 保留 |
| `codegraph-review` | 改码前波及面评估 | v3.0 保留 |
| **`autonomous-delivery`** | **端到端 6 阶段 pipeline 自动化** | 🆕 **移植自迁移手册** |
| **`agent-bridge`** | **多 Agent 桥接（claude/codex 后台并行）** | 🆕 **移植自迁移手册** |
| **`cross-language`** | **跨语言开发适配（语言特性分发）** | 🆕 **新增** |

### 2.3 通用角色库（16 个，跨项目通用）

```
全局角色（~/.claude/agents/）:
├── 全栈类
│   ├── backend-developer     通用后端开发（Java/Go/Python/Node/Rust 等自适应）
│   ├── frontend-developer    通用前端开发（Vue/React/Svelte/小程序等自适应）
│   ├── fullstack-developer   全栈（前后端贯通）
│   └── mobile-developer      移动端（iOS/Android/Flutter/RN）
├── 专业类
│   ├── dba                   数据库设计与优化（MySQL/PG/DM/Oracle 适配）
│   ├── devops                CI/CD + 容器化 + 部署
│   ├── test-engineer         测试（单测/集成/E2E）
│   └── security-reviewer     安全审计
├── 审查类
│   ├── code-reviewer         通用代码审查
│   ├── architect             架构决策
│   └── planner               实施计划
└── 管理类
    ├── project-manager       PM 拆解/跟踪/风险
    ├── build-error-resolver  构建错误修复
    ├── docs-writer           文档生成
    └── tdd-guide             TDD 强制方法论
```

---

## 三、相对 v3.0 的改动清单

| # | 改动 | 来源 | 落点 |
|---|------|------|------|
| 1 | **去建投专属命名**：主人格称呼改为"工程师"（原"芦哥"），移除"国资本项目"等场景绑定 | 用户要求跨项目通用 | SOUL.md 沟通风格 |
| 2 | **替换建投红线**：删除数据访问白名单/禁 MyBatis/Entity AI 禁改 等建投专属约束 | 跨语言需要 | AGENTS.md §六 → 改为通用最佳实践 |
| 3 | **引入跨语言适配**：新增 `cross-language` 技能，按语言特性动态加载规范 | 用户要求无特定语言 | skills/cross-language/ |
| 4 | **新增 autonomous-delivery 技能**：端到端 6 阶段 pipeline（需求→开发→接口→联调→修复→交付） | 移植迁移手册 §4.5 | skills/autonomous-delivery/ |
| 5 | **新增 agent-bridge 技能**：统一封装 claude/codex 后台并行调用 | 移植迁移手册 §4.7 | skills/agent-bridge/ |
| 6 | **新增 09_移交文档模板（HANDOFF）**：跨 Agent 任务交接契约 | 移植迁移手册 §附录 A.1 | Hermes模板库/09_*.md |
| 7 | **新增 10_版本记录模板（version.md）**：每次改文件记录修改内容与版本号 | 移植迁移手册 §development-workflow | Hermes模板库/10_*.md |
| 8 | **新增 11_跨语言适配清单**：按语言类型分发的规范索引 | 新增 | Hermes模板库/11_*.md |
| 9 | **新增通用编码规范文档**：替代建投专属 coding-style | 移植迁移手册 §coding-style | Hermes模板库/00_编码规范_通用.md |
| 10 | **新增 scripts/pipeline.py**：6 阶段端到端流水线（可独立运行） | 移植迁移手册 附录 E | scripts/pipeline.py |
| 11 | **新增 scripts/agent-bridge.sh**：多 Agent 桥接脚本 | 移植迁移手册 附录 B.1 | scripts/agent-bridge.sh |
| 12 | **精简角色库**：32 建投专属 → 16 通用（覆盖前后端/DBA/测试/PM/审查/构建/安全） | 用户要求跨项目 | ~/.claude/agents/ |
| 13 | **角色库文档化**：新增 `通用角色库说明.md` 解释 16 个角色定位 | 新增 | README + 各角色 md |
| 14 | **AGENTS.md 加章节**：自动流水线（§六）、跨语言开发（§七）、通用角色库（§八） | 融合扩展 | Hermes_制度层.md |
| 15 | **删除桌面 Kanban 插件源码**：v3.0 已用框架内置 `hermes kanban`，迁移手册的 plugin.js 与之重复 | 简化 | （不部署 plugin.js） |

---

## 四、目录结构（融合后）

```
hermes-workflow-kit/
├── README.md                              ← 1 行简介
├── README_改动说明与使用指南.md            ← 本文件（v4.0 融合版）
├── Hermes_主人格.md                       ← 跨项目通用版（部署时 = SOUL.md）
├── Hermes_制度层.md                       ← 融合版（部署时 = AGENTS.md）
├── Hermes模板库/
│   ├── 00_模板索引与使用说明.md
│   ├── 00_编码规范_通用.md                 ← 🆕 跨语言通用规范
│   ├── 01_PRD需求文档模板.md
│   ├── 02_HLD概要设计模板.md
│   ├── 03_DD详细设计模板.md
│   ├── 04_任务卡模板.md
│   ├── 05_会议纪要模板.md
│   ├── 06_进度报告模板.md
│   ├── 07_交付验证报告模板.md
│   ├── 08_看板卡片模板.md
│   ├── 09_移交文档模板.md                  ← 🆕 HANDOFF（跨 Agent 交接契约）
│   ├── 10_版本记录模板.md                  ← 🆕 version.md（修改追溯）
│   └── 11_跨语言适配清单.md                ← 🆕 语言特性分发索引
├── skills/
│   ├── project-workflow/                  ← v3.0 保留（七阶段入口）
│   ├── kanban-executor/                   ← v3.0 保留（任务生命周期）
│   ├── codegraph-review/                  ← v3.0 保留（波及面评估）
│   ├── autonomous-delivery/               ← 🆕 pipeline 自动化
│   ├── agent-bridge/                      ← 🆕 多 Agent 桥接
│   └── cross-language/                    ← 🆕 跨语言适配
├── scripts/
│   ├── pipeline.py                        ← 🆕 6 阶段端到端流水线
│   ├── agent-bridge.sh                    ← 🆕 多 Agent 桥接脚本
│   └── sync-roles-to-profiles.sh          ← 🆕 角色库→profile 同步
└── 通用角色库说明.md                       ← 🆕 16 角色定位与调用约定
```

> 注：通用角色库的 16 个 `.md` 文件推荐部署到 `~/.claude/agents/`（用户级），由 `sync-roles-to-profiles.sh` 一键同步到 Hermes profiles。

---

## 五、部署步骤（融合版）

> ⚠️ 同样有两个 Hermes home，先确认部署目标：
> - **CLI/网关实例** home = `C:\Users\luchunqing\.hermes\`
> - **桌面版（Hermes Studio）** home = `C:\Users\luchunqing\AppData\Local\hermes\`
> 两个实例的 SOUL.md 互不相通，要在哪个实例生效就部署到哪个目录（或都部署）。

```bash
# ═══ 1. 备份现有人格 ═══
cp ~/.hermes/SOUL.md ~/.hermes/SOUL.md.bak.20260908
cp ~/.hermes/AGENTS.md ~/.hermes/AGENTS.md.bak.20260908

# ═══ 2. 复制主人格与制度层（部署时重命名） ═══
cp "E:/GitHub/hermes-workflow-kit/Hermes_主人格.md" ~/.hermes/SOUL.md
cp "E:/GitHub/hermes-workflow-kit/Hermes_制度层.md" ~/.hermes/AGENTS.md

# ═══ 3. 复制模板库与脚本 ═══
cp -r "E:/GitHub/hermes-workflow-kit/Hermes模板库" ~/.hermes/Hermes模板库
cp -r "E:/GitHub/hermes-workflow-kit/skills" ~/.hermes/skills
mkdir -p ~/.hermes/scripts
cp -r "E:/GitHub/hermes-workflow-kit/scripts/." ~/.hermes/scripts/
chmod +x ~/.hermes/scripts/*.sh

# ═══ 4. 部署通用角色库到 Claude Code ═══
mkdir -p ~/.claude/agents
# 从仓库根目录的 通用角色库说明.md 旁的 16 个 .md 文件复制到 ~/.claude/agents/
# （详见 通用角色库说明.md）

# ═══ 5. 同步角色到 Hermes profiles ═══
bash ~/.hermes/scripts/sync-roles-to-profiles.sh
# 验证：hermes profile list 应显示 16 个

# ═══ 6. 重启 Hermes 进程 ═══
# 桌面端/网关/CLI 退出重开
```

> 回滚：把 `.bak.20260908` 备份拷回原名即可。

---

## 六、怎么使用（融合版）

### 6.1 三种使用模式（择一启动）

| 模式 | 适用场景 | 触发词 | 工作流 |
|------|---------|--------|--------|
| **轻量模式**（Tier 0/1） | 查询、单点修复、单模块小需求 | "直接改"、"快修一下" | 不走流程，直接执行 |
| **严谨模式**（Tier 2 流程） | 多模块/多任务/需求模糊 | "走全流程"、"按流程交付" | 七阶段状态机（project-workflow） |
| **自动模式**（Tier 2 自动） | 需求清晰、可全自动跑通 | "用 pipeline 自动跑"、"端到端交付" | autonomous-delivery 技能 |

### 6.2 严谨模式典型流程（Tier 2）

```
用户给模糊需求
   ↓
[project-workflow]
S1 澄清 → S2 PRD（读模板 01，建追踪矩阵）
   ↓
S3 HLD/DD（读模板 02/03，设计条目回溯 US 编号）
   ↓
S4 拆任务（读模板 04，单卡 ≤4h，files_scope 不重叠）
   ↓
[kanban-executor 建卡派发]
   ↓
[codegraph-review 编码前波及面评估（可选但推荐）]
   ↓
S5 跟踪（检查点驱动，三态汇报）
   ↓
[agent-bridge 后台并行编码（可选）]
   ↓
S6 验证（7 项验证 + 追踪矩阵闭环）
   ↓
S7 归档（看板卡片 + 交付报告）
```

### 6.3 自动模式典型流程（autonomous-delivery）

```bash
# 单条命令端到端跑通 6 阶段
python ~/.hermes/scripts/pipeline.py \
  --project my-app \
  --task "实现用户登录接口" \
  --lang python
```

流水线内部：需求分析 → 代码开发（Claude Code）→ 接口测试（curl）→ 页面联调（Playwright，可选）→ 缺陷修复 → 交付归档

每阶段最多 2 次重试，间隔 5s；失败自动升级。
报告输出：`~/.workbuddy/pipeline-reports/01-requirement.json` ~ `06-deliver.json`

### 6.4 跨语言开发工作流

启动 Tier 2 任务时，先读 `cross-language` 技能确定目标语言特性：
- **强类型编译型**（Java/Go/Rust/Kotlin/C++）→ 严格类型 + 编译期检查
- **动态解释型**（Python/JS/Ruby）→ 类型注解 + 测试覆盖 ≥80%
- **脚本型**（Bash/PowerShell）→ 安全第一（参数校验/路径白名单）
- **混合栈**（前端 + 后端）→ 双技能加载（`cross-language` + 对应前后端规范）

详见模板 11 与 skills/cross-language/SKILL.md。

### 6.5 编码委派（融合版）

**三种姿势，按任务选型**：

| 姿势 | 适用 | 命令 |
|------|------|------|
| **Print 模式**（首选） | 大多数单任务 | `claude -p "读 TASK.md 并执行" --max-turns 10` |
| **agent-bridge 后台并行** | 多任务不共写文件 | `bash agent-bridge.sh claude backend-developer "..."` |
| **pipeline 自动跑** | 端到端交付 | `python pipeline.py --project X --task "..."` |

**委派纪律（融合）**：
1. 任务内容必须落盘到 `TASK.md`，启动指令 ≤4KB（"读 TASK.md 并执行"）
2. 禁止：`$(cat 全文件)` / `--system` flag / `>4KB` 内联长指令
3. 委派后必须验证：`git status --short` + `git diff --stat HEAD`
4. **零产出 → 立即 STOP → 转手动 patch**（不是换模型能解决）
5. 走工作流时 Hermes 不亲自改码，只拆需求→写卡→派发→独立验收

---

## 七、注意事项

- **模板铁律不变**：先读后写、按节填写、`【】` 占位符清零、`>💡` 指引定稿删除
- **协商触发**：歧义/冲突/复杂度命中即开会（L2+），L3 不可逆操作必须用户终审
- **看板状态以 `hermes kanban` 为事实源**，聊天口头进度须核实后落板
- **跨项目适用**：部署一次到全局 Hermes home，所有项目共享同一套工作流
- **角色库自适应**：每个 Agent 启动时自动加载目标语言规范（来自 cross-language 技能）
- **流水线谨慎启用**：autonomous-delivery 适合"需求清晰、环境齐备"的场景；Tier 2 复杂需求仍走人工七阶段