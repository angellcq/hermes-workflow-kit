---
name: autonomous-delivery
description: "Use when 需求清晰/环境齐备/可全自动跑通端到端交付. 6 阶段 pipeline 自动化 SOP. 触发词: pipeline 自动跑/端到端交付/一键交付"
version: 1.0.0
platforms: [windows, linux, macos]
---

# Autonomous Delivery Skill

端到端 6 阶段流水线自动化技能。把"需求 → 交付"的全过程封装为可重入、可观测、可重试的 pipeline。

> 适用场景：需求清晰、环境齐备、目标语言明确、不需要复杂人工协商的中小型任务。
> 不适用场景：需求模糊、跨模块架构变更、需要人工终审的不可逆操作。

---

## 入口与触发

```bash
# 单条命令端到端跑通
python .hermes/scripts/pipeline.py \
  --project my-app \
  --task "实现用户登录接口" \
  --lang python
```

**触发词**：「pipeline 自动跑」「端到端交付」「一键交付」「自动跑通」

---

## 6 阶段流转

```
[01 需求分析] → [02 代码开发] → [03 接口测试] → [04 页面联调（可选）]
       → [05 缺陷修复] → [06 交付归档]
```

| 阶段 | 工具 | 输入 | 输出 | 重试上限 |
|------|------|------|------|---------|
| 01 需求分析 | Hermes | 任务描述 | `01-requirement.json` | 1 次 |
| 02 代码开发 | Claude Code `claude -p` | 需求分析 + 项目根 | `02-code.json`（含 diff） | 2 次 |
| 03 接口测试 | curl / pytest / jest | 代码产出 | `03-api-test.json` | 2 次 |
| 04 页面联调（可选） | Playwright MCP | 前端改动 | `04-e2e.json` | 2 次 |
| 05 缺陷修复 | Claude Code | 失败用例 | `05-fix.json` | 2 次 |
| 06 交付归档 | Hermes | 全部阶段报告 | `06-deliver.json` | 1 次 |

每阶段最多 2 次重试，间隔 5s；③④ 失败自动进入 ⑤ 修复阶段。

---

## 项目配置（`config/projects.yaml`，非脚本内）

> v4.4 起 `pipeline.py` 不再内置 `PROJECTS` 字典：项目注册表外置为
> **`config/projects.yaml`（唯一事实源）**，由 `load_projects()` 纯函数加载。
> 字段说明与模板见该文件头部注释。

```yaml
# config/projects.yaml
my-app:
  path: "D:\\projects\\my-app"
  workdir: "D:\\projects\\my-app"
  lang: python
  test_cmd: "pytest"
  api_test_cmd: "pytest tests/api"
  build_cmd: "make build"
  skip_e2e: false
```

加载顺序：`--projects-config` 显式指定 → 环境变量 `HERMES_PROJECTS_YAML` →
`~/.hermes/config/projects.yaml` → 仓库内置示例。

---

## 报告输出

所有阶段报告输出到 `~/.workbuddy/pipeline-reports/<project>/<YYYYMMDD-HHmm>/`：

```
~/.workbuddy/pipeline-reports/my-app/20260904-1800/
├── 01-requirement.json      # 需求分析结果（含澄清问题）
├── 02-code.json             # 代码改动（含 diff 摘要）
├── 03-api-test.json         # 接口测试结果
├── 04-e2e.json              # 页面联调结果（可选）
├── 05-fix.json              # 缺陷修复记录
├── 06-deliver.json          # 交付清单
└── pipeline.log             # 全流程日志
```

每个 JSON 结构：

```json
{
  "stage": "01-requirement",
  "status": "success" | "failed" | "retrying",
  "start_time": "2026-09-04T18:00:00+08:00",
  "end_time": "2026-09-04T18:00:30+08:00",
  "duration_seconds": 30,
  "retry_count": 0,
  "input": { ... },
  "output": { ... },
  "error": null | { "type": "...", "message": "...", "trace": "..." }
}
```

---

## 阶段详解

### 阶段 01：需求分析

**目标**：把用户输入的自然语言任务转为结构化需求

**输入**：
- 用户自然语言任务描述（`--task` 参数）
- 项目根目录（读取 README/AGENTS.md）

**处理**：
1. 读取项目根的 README、AGENTS.md、最近 git log（了解上下文）
2. 用 Hermes 分析任务，识别：
   - 输入/输出
   - 涉及的文件范围（files_scope）
   - 验收标准（可测试条件）
   - 涉及的依赖（外部接口/库）
3. 输出结构化需求文档

**输出**：`01-requirement.json` 含 `requirements` / `files_scope` / `acceptance` / `dependencies`

**失败处理**：分析不出验收标准 → 报告"任务不可验证"并退出（不进入 02）

---

### 阶段 02：代码开发

**目标**：基于需求分析产出实际代码改动

**工具**：Claude Code `claude -p` 模式

**输入**：01 阶段产物 + 项目根

**处理**：
1. 创建临时 worktree：`git worktree add /tmp/pipeline-<project>-<ts>`
2. 在 worktree 内写 `TASK.md`（任务详细说明）
3. 启动命令（≤4KB）：
   ```bash
   claude -p "读 TASK.md 并执行。完成后输出 diff 摘要到 /tmp/diff_summary.txt" \
     --workdir /tmp/pipeline-<project>-<ts> \
     --allowedTools "Read,Edit,Write,Bash,Grep" \
     --max-turns 15 \
     --output-format json
   ```
4. 等待完成，检查退出码
5. 验证产出：`git diff --stat HEAD` 必须非空
6. **零产出 → 立即 STOP → 转手动 patch**（参见 §失败兜底）

**输出**：`02-code.json` 含 `commits` / `diff_stat` / `files_changed`

**失败处理**：
- 委派失败（零产出）→ STOP，输出错误，建议用户手动处理
- 编译失败 → 自动重试 1 次（让 Claude 修编译错误）
- 仍失败 → 进入 05 修复阶段

---

### 阶段 03：接口测试

**目标**：验证 API 端到端可用

**工具**：curl / 项目自带接口测试命令

**输入**：02 阶段产出 + 项目配置 `backend_base`

**处理**：
1. 启动服务（如需要）：`make serve` 或后台进程
2. 等待服务就绪（端口检查）
3. 跑接口测试：`api_test_cmd`
4. 收集测试结果

**输出**：`03-api-test.json` 含 `total` / `passed` / `failed` / `failures[]`

**失败处理**：测试失败 → 自动进入 05 修复阶段

---

### 阶段 04：页面联调（可选）

**目标**：验证前端 + 后端联调可用

**工具**：Playwright MCP（浏览器自动化）

**输入**：02 阶段产出 + 项目配置 `frontend_url`

**处理**：
1. 启动前端（如需要）
2. 用 Playwright 打开关键页面
3. 执行核心交互流程
4. 截图 + 错误检测

**输出**：`04-e2e.json` 含 `screenshots[]` / `errors[]`

**失败处理**：浏览器错误 → 进入 05 修复

**跳过条件**：`--skip-e2e` 参数 或 `PROJECTS[project].skip_e2e = True`

---

### 阶段 05：缺陷修复

**目标**：自动修复 03/04 阶段的失败用例

**工具**：Claude Code `claude -p`

**输入**：失败用例 + 代码上下文

**处理**：
1. 把失败用例整理为 `BUGS.md`
2. 启动 Claude Code 修复：
   ```bash
   claude -p "读 BUGS.md 并修复。修复后跑测试确认通过。" \
     --workdir /tmp/pipeline-<project>-<ts> \
     --allowedTools "Read,Edit,Write,Bash,Grep" \
     --max-turns 10
   ```
3. 重跑 03/04 验证
4. **修复闭环最多 2 轮**，第 3 轮失败转 L2 协商上浮

**输出**：`05-fix.json` 含 `fixed` / `still_failing` / `escalate`

---

### 阶段 06：交付归档

**目标**：整理交付物 + 清理 worktree + 通知用户

**处理**：
1. 把 worktree 改动合并回主分支（用户确认后）
2. 更新 `.hermes/Hermes模板库/10_版本记录模板.md`（追加本次变更）
3. 清理 worktree
4. 输出最终交付报告

**输出**：`06-deliver.json` 含 `summary` / `files_changed` / `test_results` / `version_log_entry`

---

## 失败兜底机制

| 失败类型 | 处理 |
|---------|------|
| 需求不可验证（01） | 退出 pipeline，要求用户澄清 |
| 委派零产出（02） | **立即 STOP**，不重试，转手动 patch |
| 编译失败 | 自动重试 1 次让 Claude 修 |
| 接口测试失败 | 进入 05 修复阶段 |
| 修复 3 轮失败 | 升级 L2 协商，要求用户介入 |
| 页面联调浏览器错误 | 进入 05 修复 |

**手动 patch 切换流程**：

```bash
# pipeline 失败后输出
{"error": "委派零产出", "worktree": "/tmp/pipeline-my-app-1234", "files_scope": [...]}

# 用户或工程师手动处理：
cd /tmp/pipeline-my-app-1234
# 手动修改文件
git add -A && git commit -m "fix: 手动修复登录逻辑"

# 续跑：pipeline 无 resume 子命令，用 --from-stage 从指定阶段重跑
python .hermes/scripts/pipeline.py --project my-app --task "..." --from-stage 03-api-test
```

---

## 使用模式

### 模式 1：完全自动（推荐需求清晰时）

```bash
python .hermes/scripts/pipeline.py --project my-app --task "..."
# 跑完全部 6 阶段，失败自动修复 2 轮
```

### 模式 2：指定跳过某些阶段

```bash
python pipeline.py --project my-app --task "..." --skip-e2e
# 跳过 04 页面联调（纯后端任务）
```

### 模式 3：从某阶段恢复

```bash
python pipeline.py --project my-app --task "..." --from-stage 03
# 从 03 接口测试开始（前置阶段已完成）
```

### 模式 4：仅分析需求（不动代码）

```bash
python pipeline.py --project my-app --task "..." --only-analyze
# 只跑 01 阶段，输出需求分析给用户审核
```

### 模式 5：干跑（不真改代码）

```bash
python pipeline.py --project my-app --task "..." --dry-run
# 全部阶段跑逻辑但不真改代码/不真测试
```

---

## 与其他技能配合

| 阶段 | 配合技能 |
|------|---------|
| 01 需求分析 | `project-workflow`（S1-S2 流程的精简版） |
| 02 代码开发 | `codegraph-review`（改码前波及面评估）+ `agent-bridge`（多 Agent 桥接可选） |
| 03 接口测试 | `kanban-executor`（任务跟踪） |
| 04 页面联调 | `agent-browser` 技能（如已安装） |
| 05 缺陷修复 | `kanban-executor`（更新卡片状态） |
| 06 交付归档 | `project-workflow`（S7 归档） |

---

## 与 project-workflow 的关系

| 维度 | autonomous-delivery | project-workflow |
|------|-------------------|------------------|
| **流程** | 6 阶段自动流水线 | 七阶段人工流程 |
| **人工介入** | 极少（仅决策性） | 频繁（每阶段都需核对） |
| **适用** | 需求清晰 / 小型任务 | 需求模糊 / 大型复杂任务 |
| **产出** | 自动化报告 | 文档驱动追踪 |
| **可观测** | 日志 + JSON 报告 | 看板 + 文档 |

**选择规则**：
- 默认人工流程（project-workflow）更稳妥
- 需求清晰、可全自动跑通时用 autonomous-delivery
- 复杂多任务时仍走 project-workflow，但可借 pipeline 加速单任务执行

---

## 已知限制

1. **不擅长 GUI 密集型应用**：04 页面联调对纯 GUI 应用有限制
2. **跨服务改动需谨慎**：涉及多个服务的任务，pipeline 可能误判 files_scope
3. **数据库迁移风险高**：DDL 操作默认走手动（不在 pipeline 范围）
4. **不可逆操作默认禁用**：发布/删除/生产数据操作需要二次确认
5. **依赖深度 >5 层任务不适用**：复杂度高，转 project-workflow

---

> **任务传递姿势 / 失败兜底机制 / 红线**：详见 `AGENTS.md §六.5`、`AGENTS.md §六.7`、`AGENTS.md §九`。本 SKILL 是 pipeline 流程编排，不重复通用规则。

---

## 部署

详见 `DEPLOY.md §5`。

---

> 版本信息见仓库根 `CHANGELOG.md`（不再每个文件单独记录）。