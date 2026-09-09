# 使用模式（USAGE）

> 三种启动姿势 + 注意事项。完整规则见 `AGENTS.md`。

## 一、三种使用模式（择一启动）

| 模式 | 适用场景 | 触发词 | 工作流 |
|------|---------|--------|--------|
| **轻量模式**（Tier 0/1） | 查询、单点修复、单模块小需求 | "直接改"、"快修一下" | 不走流程，直接执行 |
| **严谨模式**（Tier 2 流程） | 多模块/多任务/需求模糊 | "走全流程"、"按流程交付" | 七阶段状态机（project-workflow） |
| **自动模式**（Tier 2 自动） | 需求清晰、可全自动跑通 | "用 pipeline 自动跑"、"端到端交付" | autonomous-delivery 技能 |

## 二、严谨模式典型流程（Tier 2）

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
S6 验证（追踪矩阵闭环）
   ↓
S7 归档（看板卡片 + 交付报告）
```

## 三、自动模式典型流程（autonomous-delivery）

```bash
# 单条命令端到端跑通 6 阶段
python .hermes/scripts/pipeline.py \
  --project my-app \
  --task "实现用户登录接口" \
  --lang python
```

流水线内部：需求分析 → 代码开发（Claude Code）→ 接口测试（curl）→ 页面联调（Playwright，可选）→ 缺陷修复 → 交付归档

每阶段最多 2 次重试，间隔 5s；失败自动升级。
报告输出：`~/.workbuddy/pipeline-reports/01-requirement.json` ~ `06-deliver.json`

## 四、跨语言开发工作流

启动 Tier 2 任务时，先读 `cross-language` 技能确定目标语言特性：

- **强类型编译型**（Java/Go/Rust/Kotlin/C++）→ 严格类型 + 编译期检查
- **动态解释型**（Python/JS/Ruby）→ 类型注解 + 测试覆盖 ≥80%
- **脚本型**（Bash/PowerShell）→ 安全第一（参数校验/路径白名单）
- **混合栈**（前端 + 后端）→ 双技能加载

详见 `Hermes模板库/编码规范_跨语言.md` 与 `skills/cross-language/SKILL.md`。

## 五、编码委派（融合版）

**三种姿势，按任务选型**：

| 姿势 | 适用 | 命令 |
|------|------|------|
| **Print 模式**（首选） | 大多数单任务 | `claude -p "读 TASK.md 并执行" --max-turns 10` |
| **agent-bridge 后台并行** | 多任务不共写文件 | `bash agent-bridge.sh claude backend-developer "..."` |
| **pipeline 自动跑** | 端到端交付 | `python pipeline.py --project X --task "..."` |

**委派纪律**：详见 `AGENTS.md §六.5` 与 `§六.7`。本文件不重复通用规则——核心：

1. 任务内容必须落盘到 `TASK.md`，启动指令 ≤4KB（"读 TASK.md 并执行"）
2. 禁止：`$(cat 全文件)` / `--system` flag / `>4KB` 内联长指令
3. 委派后必须验证：`git status --short` + `git diff --stat HEAD`
4. **零产出 → 立即 STOP → 转手动 patch**（不是换模型能解决）
5. 走工作流时 Hermes 不亲自改码，只拆需求→写卡→派发→独立验收

## 六、注意事项

- **模板铁律不变**：先读后写、按节填写、`【】` 占位符清零、`>💡` 指引定稿删除
- **协商触发**：歧义/冲突/复杂度命中即开会（L2+），L3 不可逆操作必须用户终审
- **看板状态以 `hermes kanban` 为事实源**，聊天口头进度须核实后落板
- **跨项目适用**：部署一次到全局 Hermes home，所有项目共享同一套工作流
- **角色库自适应**：每个 Agent 启动时自动加载目标语言规范（来自 cross-language 技能）
- **流水线谨慎启用**：autonomous-delivery 适合"需求清晰、环境齐备"的场景；Tier 2 复杂需求仍走人工七阶段
