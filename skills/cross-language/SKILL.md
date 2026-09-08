---
name: cross-language
description: "Use when 任务涉及任意开发语言/启动编码前需加载语言规范. 按语言类型分发编码规范与工具链."
version: 1.0.0
platforms: [windows, linux, macos]
---

# Cross-Language Skill

跨语言开发适配技能。按目标语言特性动态加载对应的编码规范、工具链、测试门槛，作为 Hermes 默认规范的细化补充。

> 适用场景：用户没有指定特定开发语言；项目根 AGENTS.md 未声明语言规范；编码 Agent 启动时需自动加载语言约束。
> 不适用场景：项目根 AGENTS.md/AGENT.md 已声明明确的语言规范（项目级优先）。

---

## 入口与触发

```bash
# 启动某个编码任务时，agent 内部自动加载本技能
# 手动查询：
bash ~/.hermes/scripts/cross-language.sh detect <项目路径>
# 输出该项目的语言类型 + 应加载的规范章节
```

**触发时机**：
- 任何 Tier 2 任务开工前（Hermes 必查）
- 编码 Agent 启动后第一件事（加载对应规范）
- 项目从其他语言迁移过来时（重新加载）

---

## 语言检测逻辑

按以下顺序检测（命中即返回）：

```
1. 项目根 AGENTS.md / .hermes.md / AGENT.md 的声明
   ↓ 缺失
2. package.json  → JavaScript/TypeScript
   pyproject.toml / setup.py / requirements.txt  → Python
   pom.xml / build.gradle / build.gradle.kts  → Java/Kotlin
   go.mod  → Go
   Cargo.toml  → Rust
   *.csproj / *.sln  → C#
   Podfile  → iOS Swift/Obj-C
   build.gradle (android)  → Android
   pubspec.yaml  → Flutter/Dart
   composer.json  → PHP
   Gemfile  → Ruby
   Mix.exs  → Elixir
   CMakeLists.txt  → C/C++
   *.cabal  → Haskell
   ↓ 缺失
3. 文件扩展名统计（占比最高的语言）
   ↓ 缺失
4. git log 作者 + 提交消息推断
   ↓ 缺失
5. 询问用户（不允许猜测）
```

---

## 语言类型与加载规范

检测到语言后，加载对应的规范章节（详见模板 11）：

| 语言/栈 | 加载章节 | 工具链 |
|---------|---------|--------|
| JavaScript / TypeScript | §3.2 + §5.2 | ESLint + Prettier + Vitest |
| Python | §3.2 | ruff + pytest |
| Java | §2.2 Java | javac + JUnit 5 + JaCoCo |
| Kotlin | §2.2 Kotlin | kotlinc + JUnit 5 + Kover |
| Go | §2.2 Go | go vet + go test |
| Rust | §2.2 Rust | cargo clippy + cargo test |
| C++ | §2.2 C++ | cmake + gtest + gcov |
| C# | §2.2 C# | dotnet build + xUnit + coverlet |
| Swift | §2.2 Swift + §6.1 | xcodebuild + XCTest |
| Ruby | §3.2 Ruby | rubocop + RSpec |
| PHP | §3.2 PHP | php-cs-fixer + PHPUnit |
| Vue 3 | §5.2 Vue 3 | ESLint + Vitest + Vue Test Utils |
| React | §5.2 React | ESLint + Vitest + RTL |
| Svelte | §5.2 Svelte | ESLint + Vitest |
| 微信小程序 | §5.2 微信小程序 | miniprogram-automator |
| Flutter | §6.3 | flutter test + integration_test |
| React Native | §6.4 | TypeScript + Hermes |
| Bash | §4.2 Bash | shellcheck + bats |
| PowerShell | §4.2 PowerShell | PSScriptAnalyzer + Pester |
| SQL | §7.1 | sqlfluff + 项目 DB 工具 |
| 混合栈 | §8 | 各栈工具链并用 |

---

## 规范优先级（重要）

```
项目根 AGENTS.md/AGENT.md/.hermes.md/README  >  本技能 + 模板 11  >  Hermes 默认规范（00_编码规范_通用.md）
```

**冲突处理**：
- 项目级与全局冲突 → 触发 L2 协商（Hermes 列差异，用户终审）
- 项目级缺失规范 → 使用模板 11 默认
- 模板 11 也缺失 → 使用 00_编码规范_通用.md 兜底

---

## 自动加载流程

### 启动编码任务时

```python
# Hermes 内部逻辑（伪代码）
def start_coding_task(task_id, workdir):
    # 1. 检测语言
    lang_info = detect_language(workdir)

    # 2. 读取项目级约定
    project_rules = read_project_rules(workdir)
    # 读取 AGENTS.md / .hermes.md / AGENT.md

    # 3. 加载全局规范
    if project_rules is None:
        # 用模板 11 + cross-language 默认
        global_rules = load_from_template_11(lang_info['type'])
    else:
        global_rules = project_rules

    # 4. 合并规范（项目级覆盖全局级）
    final_rules = merge_rules(global_rules, project_rules)

    # 5. 附加到任务卡
    task_card.add_constraints(final_rules)

    # 6. 编码 Agent 启动时附带
    return final_rules
```

### 编码 Agent 启动时

```
# Claude Code system prompt 中追加（自动）：

You are working on a <language> project.

Applicable rules (priority: project > global > default):
<final_rules>

Cross-language considerations for <language>:
- Specific toolchain: <tools>
- Test coverage threshold: <threshold>
- Linter/Formatter: <tools>
- Build command: <command>
```

---

## 跨语言协作场景

### 场景 1：全栈项目（前后端分离）

检测到同时有 `package.json`（前端）和 `pom.xml`（后端 Java）：

```
加载规范：
- 前端：§5.2 Vue/React + §8 混合栈
- 后端：§2.2 Java + §8 混合栈

约束：
- 跨边界接口必须用 OpenAPI 定义
- 双技能加载（前后端 Agent 各自加载规范）
- 测试覆盖率门槛取最高（前端 70% + 后端 80% → 取 80%）
- 跨边界用契约测试（Pact / WireMock）
```

### 场景 2：移动端 + 后端 API

检测到 `pubspec.yaml`（Flutter）和 `go.mod`（Go）：

```
加载规范：
- 移动端：§6.3 Flutter
- 后端：§2.2 Go

约束：
- API 契约：Protobuf / OpenAPI
- 后端生成的 client SDK 必须被移动端使用（禁止手写）
- 双端版本号同步（协议版本 v1.0.0 → 前后端同时升级）
```

### 场景 3：多语言迁移（Python → Go）

检测到 `go.mod` 但 git log 显示最近 6 个月是 Python：

```
触发 L2 协商：
- 是否完全迁移？
- 是否并行维护？
- 跨语言调用如何处理（HTTP/gRPC/Message Queue）？

约束：
- 新代码必须用 Go
- 旧 Python 代码除非 bug fix 否则不动
- 接口边界明确：Go 服务暴露 REST，Python 服务调用
```

---

## 工具链安装提示

加载规范时附带工具链安装命令（用户确认后执行）：

```bash
# Python 项目
pip install ruff pytest pytest-cov

# Node 项目
npm install -D eslint prettier vitest @vitest/coverage-v8

# Go 项目
go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest

# Rust 项目
cargo install cargo-llvm-cov

# Java 项目
# Maven
mvn install
# Gradle
./gradlew build
```

---

## 已知限制

1. **不擅长小众语言**：Cobol/Ada/Erlang 等小众语言规范可能不完整
2. **不替代项目约定**：永远以项目根 AGENTS.md 为准
3. **不强制升级语言栈**：仅在用户明确同意时才升级工具链版本
4. **跨语言性能优化不深入**：仅给通用建议，深度优化需要架构师

---

## 与其他技能配合

| 场景 | 配合技能 |
|------|---------|
| 项目启动时检测 | `project-workflow`（S0 需求受理时自动加载） |
| 编码前 | `codegraph-review`（波及面评估 + 加载语言规范） |
| 编码委派 | `agent-bridge`（把语言规范附加到任务卡） |
| 端到端 pipeline | `autonomous-delivery`（自动检测并加载） |

---

## 红线（融合版）

- 不替项目做主：项目根 AGENTS.md 永远是最高优先级
- 不假设语言：检测失败时必须询问用户
- 不强制迁移：不主动建议"换语言更好"，除非用户询问
- 不忽略版本约束：检测语言时同时检测版本（Python 3.8 vs 3.12 规范不同）

---

## 部署

```bash
# 部署脚本
cp scripts/cross-language.sh ~/.hermes/scripts/
chmod +x ~/.hermes/scripts/cross-language.sh

# 配套模板（已部署到 ~/.hermes/Hermes模板库/11_跨语言适配清单.md）
```

---

## 版本记录

| 版本 | 日期 | 修改人 | 修改说明 |
|------|------|--------|---------|
| v1.0 | 2026-09-08 | Hermes | 初稿（融合版） |