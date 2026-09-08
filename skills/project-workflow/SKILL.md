---
name: project-workflow
description: "Use when 用户说走全流程/启动项目交付工作流. 七阶段交付流程入口SOP."
version: 1.0.0
platforms: [windows, linux, macos]
---

# Project Workflow Skill

项目结构化交付工作流入口 SOP。触发词：「走全流程」「启动项目工作流」「按流程交付」。

## 七阶段状态机

```
S0 需求受理 → S1 需求澄清 → S2 PRD编写 → S3 HLD/DD设计
    → S4 任务拆解与派发 → S5 开发跟踪检查 → S6 最终验证 → S7 看板归档
```

## 适用判定（先判，再动手）

| 任务类型 | 流程 |
|---------|------|
| 查询/单点修复/改配置 | **不走流程**，直接执行 |
| 单模块功能裁剪 | 澄清 → 任务卡 → 执行 → 验证（简化四步） |
| 多任务交付/需求有歧义/需合规追溯 | **完整七阶段** |

> 用户说「走全流程」强制启用；说「直接改」强制跳过。

## 各阶段操作要点

### S1 需求澄清
- 澄清问题一次性列出，≤2 轮
- 命中歧义/冲突/复杂度 → 触发协商（L1 确认 / L2 开会 / L3 开会+用户终审）
- 准出：歧义清单为空，或已形成决议

### S2 PRD 编写
- 先读 `.hermes/Hermes模板库/01_PRD需求文档模板.md` 全文
- 建立追踪矩阵（US 编号 ↔ 设计 ↔ 任务卡 ↔ 验证项）
- 产出：`doc/PRD_项目名_功能名_v版本.md`

### S3 HLD/DD 设计
- 先读 `02_HLD概要设计模板.md` / `03_DD详细设计模板.md`
- 每条设计条目回溯需求编号，接口冻结
- 产出：`doc/HLD_*.md` / `doc/DD_*.md`

### S4 任务拆解与派发
- 先读 `04_任务卡模板.md`
- 拆解五原则：可验收 / 低耦合 / 单事务(≤4h) / 显式依赖 / 有回溯
- 每张卡 → `hermes kanban create` + 写 TASK.md
- 派发策略：独立并行 / 依赖串行 / 同文件强制串行

### S5 开发跟踪
- 检查点驱动：派发确认时 / 里程碑 / 用户询问 / 阻塞时
- 状态机：TODO → IN_PROGRESS → IN_REVIEW → DONE / BLOCKED
- 进度预警：<70% 黄警 / <50% 红警

### S6 最终验证
- 需求覆盖：追踪矩阵每条需求 → ≥1 张 DONE 卡 → ≥1 通过验证项
- 交付物完整：文档齐套 / 版本一致 / 变更闭合 / 异常清零
- 编码交付：`git diff --stat` 确认变更 + `dotnet build` / `mvn compile` 编译通过

### S7 归档交付
- `hermes kanban archive` 归档全部卡片
- 交付物清单齐套

## 编码委派规范（Claude Code）

**核心原则：执行管道而非阅读理解引擎。**

1. 先建 worktree，prompt 写入 worktree 内 TASK.md
2. 启动指令 ≤4KB（读 TASK.md 并执行），**禁止**：`$(cat 全文件)` / `--system` / `>4KB` 内联
3. 结束后验 `git status --short` + `git diff --stat HEAD`
4. 零产出 → 立即 STOP → 转手动 patch（不是换模型能解决）
5. 走工作流时 Hermes 不亲自改码：只拆需求→写卡→派发→独立验收
6. 派发时不管用户用什么模型，不干预 cc-switch

## 红线（冲突时技术红线优先）

- Controller 禁业务逻辑；URL 全小写
- 数据访问白名单：IBillQueryRepository / IBillRepository / IYmsJdbcApi
- 实体类 AI 禁改
- 禁 MyBatis / BaseDAO / DataSource / JPA
- HTTP 仅 YmsHttpClientUtil，URL 走配置中心禁硬编码
