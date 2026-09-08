# Hermes Workflow Kit

Hermes 多 Agent 开发工作流套件：人格（SOUL）+ 制度（AGENTS）+ 模板库 + 通用角色库 + 技能与脚本，覆盖从需求澄清到交付验证的全链路。

## 架构总览

```
┌─────────────────────────────────────────────────────────┐
│                     运行时人格层                          │
│  Hermes_主人格.md ──→ 部署为 ~/.hermes/SOUL.md（人格）     │
│  Hermes_制度层.md  ──→ 部署为 ~/.hermes/AGENTS.md（规则）  │
└──────────────┬──────────────────────────────────────────┘
               │ 按需引用
┌──────────────┴──────────┬────────────────┬──────────────┐
│       Hermes模板库      │    通用角色库    │    skills    │
│  PRD/HLD/DD/任务卡/    │  16 个跨项目     │  project-    │
│  会议纪要/进度报告/     │  通用角色 .md    │  workflow /  │
│  交付验证/看板/HANDOFF  │  ──→ 部署到     │  agent-bridge│
│  /编码规范_跨语言.md    │  ~/.claude/     │  /cross-     │
│       （按环节取用）    │  agents/*.md    │  language …  │
└────────────────────────┴────────────────┴──────┬───────┘
                                                   │ 调用
                                          ┌────────┴────────┐
                                          │     scripts      │
                                          │ agent-bridge.sh  │
                                          │ pipeline.py …    │
                                          └─────────────────┘
```

## 快速开始

```bash
# 1. 部署人格、角色库与脚本（含两个 Hermes home 的说明）
#    详见 DEPLOY.md

# 2. 验证
bash ~/.hermes/scripts/agent-bridge.sh roles   # 列出角色（动态扫描）

# 3. 使用（三种模式：轻量 / 严谨 / 自动）
#    详见 USAGE.md

# 4. 运行测试集（脚本语法 / 角色加载 / pipeline 冒烟 / 引用完整性）
bash tests/run_tests.sh
```

## 目录说明

| 路径 | 内容 | 事实源职责 |
|------|------|-----------|
| `Hermes_主人格.md` | 人格：价值观、沟通风格 | 人格唯一源 |
| `Hermes_制度层.md` | 制度：七阶段流程、委派规范、军规 | 流程与协议唯一源 |
| `Hermes模板库/` | 01-10 文档模板 + 编码规范_跨语言.md | 编码规范唯一源 |
| `通用角色库/` + `通用角色库说明.md` | 16 角色定义与清单 | **角色清单唯一源**（agent-bridge.sh 动态扫描自动同步） |
| `skills/` | project-workflow / agent-bridge / autonomous-delivery / cross-language 等 | 技能入口 |
| `scripts/` | agent-bridge.sh / pipeline.py / check-references.py 等 | 可执行工具 |
| `tests/` | 最小测试集（run_tests.sh） | 回归防线 |
| `DEPLOY.md` | 部署 SOP | — |
| `USAGE.md` | 三种使用模式 | — |
| `CHANGELOG.md` | 版本变更账本 | 版本记录唯一源 |

## 关键约定（单一事实源）

| 信息 | 唯一源 | 其他位置 |
|------|--------|---------|
| 委派规范 / 失败兜底 | `Hermes_制度层.md` §六 | SKILL.md 引用 |
| 角色清单 | `通用角色库说明.md` §二 + 角色 .md | agent-bridge.sh 运行时扫描 |
| 编码规范（跨语言） | `Hermes模板库/编码规范_跨语言.md` | 角色文件引用 |
| 版本记录 | `CHANGELOG.md` | 各文件不再附版本小表 |

## 许可

见 [LICENSE](LICENSE)。
