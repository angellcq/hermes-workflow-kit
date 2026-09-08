#!/usr/bin/env bash
# Hermes Cross-Language — 语言检测脚本
# 检测项目根目录的开发语言类型
#
# Usage:
#   bash cross-language.sh detect <项目路径>
#   bash cross-language.sh list

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[lang]${NC} $*"; }
warn() { echo -e "${YELLOW}[lang]${NC} ⚠ $*"; }
err()  { echo -e "${RED}[lang]${NC} ✗ $*"; }

cmd_detect() {
  local project_path="${1:-.}"

  if [[ ! -d "$project_path" ]]; then
    err "目录不存在：$project_path"
    return 1
  fi

  log "检测项目：$project_path"
  echo ""

  # 优先级 1：项目根 AGENTS.md / .hermes.md / AGENT.md
  for f in AGENTS.md .hermes.md AGENT.md README.md; do
    if [[ -f "$project_path/$f" ]]; then
      # 提取 language / lang 字段
      local lang
      lang=$(grep -iE "^(language|lang|stack|tech)[:=]" "$project_path/$f" 2>/dev/null | head -1 | sed 's/^[^:=]*[:=][[:space:]]*//')
      if [[ -n "$lang" ]]; then
        echo "✓ 项目级声明：$f → language=$lang"
        return 0
      fi
    fi
  done

  # 优先级 2：特征文件检测
  declare -A markers=(
    ["package.json"]="javascript/typescript"
    ["pyproject.toml"]="python"
    ["setup.py"]="python"
    ["requirements.txt"]="python"
    ["pom.xml"]="java"
    ["build.gradle"]="java/kotlin"
    ["build.gradle.kts"]="kotlin"
    ["go.mod"]="go"
    ["Cargo.toml"]="rust"
    ["*.csproj"]="csharp"
    ["*.sln"]="csharp"
    ["Podfile"]="ios-swift"
    ["pubspec.yaml"]="flutter/dart"
    ["composer.json"]="php"
    ["Gemfile"]="ruby"
    ["Mix.exs"]="elixir"
    ["CMakeLists.txt"]="cpp"
    ["stack.yaml"]="haskell"
  )

  for marker in "${!markers[@]}"; do
    if ls "$project_path"/$marker 2>/dev/null | head -1 | grep -q .; then
      echo "✓ 特征文件匹配：$marker → ${markers[$marker]}"
      return 0
    fi
  done

  # 优先级 3：扩展名统计
  if command -v find &>/dev/null; then
    local counts
    counts=$(find "$project_path" -maxdepth 3 -type f \
      \( -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.go" \
         -o -name "*.rs" -o -name "*.java" -o -name "*.kt" -o -name "*.cs" \
         -o -name "*.swift" -o -name "*.dart" -o -name "*.rb" -o -name "*.php" \) \
      2>/dev/null | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -3)

    if [[ -n "$counts" ]]; then
      echo "✓ 扩展名统计（前三）："
      echo "$counts"
      return 0
    fi
  fi

  warn "无法自动检测，请手动指定："
  echo "  请编辑项目根 AGENTS.md，添加：language=<your-lang>"
}

cmd_list() {
  echo "═══ 支持的语言类型 ═══"
  echo ""
  echo "强类型编译型："
  echo "  java, kotlin, go, rust, cpp, csharp, swift"
  echo ""
  echo "动态解释型："
  echo "  javascript, typescript, python, ruby, php"
  echo ""
  echo "脚本型："
  echo "  bash, powershell, makefile"
  echo ""
  echo "前端框架："
  echo "  vue, react, svelte, wechat-mp"
  echo ""
  echo "移动端："
  echo "  ios-swift, android-kotlin, flutter, react-native"
  echo ""
  echo "数据/ML："
  echo "  sql, python-ml, r"
  echo ""
  echo "混合栈："
  echo "  fullstack, microservices, polyglot"
}

main() {
  if [[ $# -lt 1 ]]; then
    echo "用法："
    echo "  bash cross-language.sh detect <项目路径>"
    echo "  bash cross-language.sh list"
    exit 1
  fi

  case "$1" in
    detect) shift; cmd_detect "$@" ;;
    list)   cmd_list ;;
    -h|--help|help)
      main
      ;;
    *)
      err "未知命令：$1"
      exit 1
      ;;
  esac
}

main "$@"