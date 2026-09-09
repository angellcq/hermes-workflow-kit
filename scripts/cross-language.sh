#!/usr/bin/env bash
# Hermes Cross-Language — 语言检测脚本
# 检测项目根目录的开发语言类型
#
# 语言清单位一事实源：config/languages.yaml（markers / extensions / categories）
# 本脚本不含任何语言硬编码清单；新增语言只改 languages.yaml。
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

# ════════════════════════════════════════════════════════════════
# languages.yaml 定位与解析（awk 解析受控子集，零依赖）
# ════════════════════════════════════════════════════════════════

# 搜索顺序：$HERMES_LANG_YAML → $HERMES_HOME/config/ → 脚本同级 ../config/
resolve_lang_config() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local candidates=(
    "${HERMES_LANG_YAML:-}"
    "${HERMES_HOME:-$(dirname "$script_dir")}/config/languages.yaml"
    "$script_dir/../config/languages.yaml"
  )
  local c
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -f "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# 提取 yaml 某顶级段（markers/extensions/categories）的内容行
_yaml_section() {
  local file="$1" section="$2"
  awk -v sec="$section" '
    $0 ~ "^"sec":" { in_sec=1; next }
    /^[a-z_]+:/    { in_sec=0 }
    in_sec && /^[[:space:]]+/ { print }
  ' "$file"
}

# markers 段 → "marker<TAB>lang" 行
load_markers() {
  _yaml_section "$LANG_CONFIG" markers | awk -F': ' '{
    key=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key); gsub(/^["'\'']|["'\'']$/, "", key)
    val=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", val); gsub(/^["'\'']|["'\'']$/, "", val)
    if (key != "" && val != "") print key "\t" val
  }'
}

# extensions 段 → 空格分隔列表
load_extensions() {
  _yaml_section "$LANG_CONFIG" extensions | tr -d '[]' | tr ',' ' ' | tr -s ' '
}

# categories 段 → "分类名<TAB>成员1 成员2 ..." 行
load_categories() {
  _yaml_section "$LANG_CONFIG" categories | awk -F': ' '{
    key=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
    val=$2; gsub(/[][]/, "", val); gsub(/,[[:space:]]*/, " ", val)
    if (key != "") print key "\t" val
  }'
}

LANG_CONFIG="$(resolve_lang_config)" || {
  err "未找到 config/languages.yaml"
  err "搜索路径：\$HERMES_LANG_YAML / \$HERMES_HOME/config/ / 仓库 config/"
  exit 1
}

# ════════════════════════════════════════════════════════════════
# 命令
# ════════════════════════════════════════════════════════════════

cmd_detect() {
  local project_path="${1:-.}"

  if [[ ! -d "$project_path" ]]; then
    err "目录不存在：$project_path"
    return 1
  fi

  log "检测项目：$project_path"
  echo ""

  # 优先级 1：项目根 AGENTS.md / .hermes.md / AGENT.md / README.md 显式声明
  local f lang
  for f in AGENTS.md .hermes.md AGENT.md README.md; do
    if [[ -f "$project_path/$f" ]]; then
      lang=$(grep -iE "^(language|lang|stack|tech)[:=]" "$project_path/$f" 2>/dev/null | head -1 | sed 's/^[^:=]*[:=][[:space:]]*//')
      if [[ -n "$lang" ]]; then
        echo "✓ 项目级声明：$f → language=$lang"
        return 0
      fi
    fi
  done

  # 优先级 2：特征文件检测（清单来自 languages.yaml markers 段）
  local marker mlang
  while IFS=$'\t' read -r marker mlang; do
    [[ -z "$marker" ]] && continue
    if ls "$project_path"/$marker 2>/dev/null | head -1 | grep -q .; then
      echo "✓ 特征文件匹配：$marker → $mlang"
      return 0
    fi
  done < <(load_markers)

  # 优先级 3：扩展名统计（清单来自 languages.yaml extensions 段）
  if command -v find &>/dev/null; then
    local -a find_args=()
    local ext first=true
    for ext in $(load_extensions); do
      if $first; then first=false; else find_args+=(-o); fi
      find_args+=(-name "*.$ext")
    done
    local counts
    counts=$(find "$project_path" -maxdepth 3 -type f \( "${find_args[@]}" \) \
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
  local cat members
  while IFS=$'\t' read -r cat members; do
    [[ -z "$cat" ]] && continue
    echo "$cat："
    echo "  $(echo "$members" | tr ' ' ',' | sed 's/,/, /g')"
    echo ""
  done < <(load_categories)
  echo "（清单事实源：config/languages.yaml）"
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
