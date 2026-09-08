# 部署指南（Deployment Guide）

> 把 Hermes Workflow Kit 部署到本机的 Hermes home。

## 一、确认部署目标

Hermes 在本机有两个 home，先确认要部署到哪个：

| 实例 | home 路径 | 用途 |
|------|----------|------|
| **CLI/网关实例** | `C:\Users\luchunqing\.hermes\` | 命令行、网关 |
| **桌面版（Hermes Studio）** | `C:\Users\luchunqing\AppData\Local\hermes\` | 桌面客户端 |

两个实例的 `SOUL.md` 互不相通。在哪个实例生效就部署到哪个目录（或都部署）。

## 二、部署步骤

```bash
# ═══ 1. 备份现有人格 ═══
cp ~/.hermes/SOUL.md ~/.hermes/SOUL.md.bak.$(date +%Y%m%d)
cp ~/.hermes/AGENTS.md ~/.hermes/AGENTS.md.bak.$(date +%Y%m%d)

# ═══ 2. 复制主人格与制度层（部署时重命名） ═══
cp "E:/GitHub/hermes-workflow-kit/Hermes_主人格.md" ~/.hermes/SOUL.md
cp "E:/GitHub/hermes-workflow-kit/Hermes_制度层.md" ~/.hermes/AGENTS.md

# ═══ 3. 复制顶层辅助文档 ═══
cp "E:/GitHub/hermes-workflow-kit/CHANGELOG.md" ~/.hermes/
cp "E:/GitHub/hermes-workflow-kit/USAGE.md" ~/.hermes/
cp "E:/GitHub/hermes-workflow-kit/通用角色库说明.md" ~/.hermes/

# ═══ 4. 复制模板库与脚本 ═══
cp -r "E:/GitHub/hermes-workflow-kit/Hermes模板库" ~/.hermes/Hermes模板库
cp -r "E:/GitHub/hermes-workflow-kit/skills" ~/.hermes/skills
mkdir -p ~/.hermes/scripts
cp -r "E:/GitHub/hermes-workflow-kit/scripts/." ~/.hermes/scripts/
chmod +x ~/.hermes/scripts/*.sh

# ═══ 5. 部署通用角色库到 Claude Code ═══
mkdir -p ~/.claude/agents
cp 通用角色库/*.md ~/.claude/agents/

# ═══ 6. 同步角色到 Hermes profiles ═══
bash ~/.hermes/scripts/sync-roles-to-profiles.sh
# 验证：hermes profile list 应显示 16 个

# ═══ 7. 重启 Hermes 进程 ═══
# 桌面端/网关/CLI 退出重开
```

> 回滚：把 `.bak.<日期>` 备份拷回原名即可。

## 三、文件总览（部署到 home 后）

```
~/.hermes/
├── SOUL.md                        ← 人格（部署自 Hermes_主人格.md）
├── AGENTS.md                      ← 制度（部署自 Hermes_制度层.md）
├── CHANGELOG.md                   ← 版本变更
├── USAGE.md                       ← 使用模式
├── 通用角色库说明.md                ← 16 角色定位
├── Hermes模板库/                   ← 12 个模板（00~11）
├── skills/                        ← 6 个 SOP
└── scripts/                       ← 4 个脚本

~/.claude/agents/                  ← 16 个角色定义（来自通用角色库/）
```
