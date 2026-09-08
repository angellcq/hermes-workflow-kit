#!/usr/bin/env bash
# Hermes Sync Roles to Profiles — 通用角色库 → Hermes profiles 同步脚本
# 把 ~/.claude/agents/*.md 一键同步为 Hermes profiles
#
# Usage:
#   bash sync-roles-to-profiles.sh [--dry-run] [--limit N]
#
# 默认行为：
#   1. 扫描 ~/.claude/agents/*.md
#   2. 对每个角色，调用 `hermes profile create <name> --no-skills`
#   3. 复制角色定义到 profiles/<name>/AGENT.md
#   4. 默认用 sonnet 模型

set -euo pipefail

CLAUDE_AGENTS_DIR="${CLAUDE_AGENTS_DIR:-$HOME/.claude/agents}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
DEFAULT_MODEL="${DEFAULT_MODEL:-sonnet}"
DRY_RUN=false
LIMIT=0

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --limit)   LIMIT="$2"; shift 2 ;;
    -h|--help)
      echo "用法：bash sync-roles-to-profiles.sh [--dry-run] [--limit N]"
      echo ""
      echo "  --dry-run  只显示会做什么，不实际执行"
      echo "  --limit N  只处理前 N 个角色"
      exit 0
      ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[sync]${NC} $*"; }
warn() { echo -e "${YELLOW}[sync]${NC} ⚠ $*"; }

# 检查 Claude Code 角色目录
if [[ ! -d "$CLAUDE_AGENTS_DIR" ]]; then
  warn "角色库目录不存在：$CLAUDE_AGENTS_DIR"
  warn "请先从 hermes-workflow-kit 仓库部署通用角色库到此目录"
  exit 1
fi

# 检查 hermes CLI
if ! command -v hermes &>/dev/null; then
  warn "未检测到 hermes CLI"
  warn "请先安装 Hermes Agent"
  exit 1
fi

# 收集角色文件
mapfile -t role_files < <(find "$CLAUDE_AGENTS_DIR" -maxdepth 1 -name "*.md" -type f | sort)

if [[ ${#role_files[@]} -eq 0 ]]; then
  warn "角色库为空：$CLAUDE_AGENTS_DIR"
  exit 1
fi

log "发现 ${#role_files[@]} 个角色定义"
echo ""

count=0
for role_file in "${role_files[@]}"; do
  role_name=$(basename "$role_file" .md)
  count=$((count + 1))

  if [[ $LIMIT -gt 0 && $count -gt $LIMIT ]]; then
    log "达到 --limit $LIMIT，停止"
    break
  fi

  # 提取角色描述（frontmatter 中的 description）
  role_desc=$(grep -E "^description:" "$role_file" 2>/dev/null | head -1 | sed 's/^description:[[:space:]]*//' | sed 's/^"//;s/"$//')
  if [[ -z "$role_desc" ]]; then
    role_desc="$role_name"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] 会创建 profile: $role_name ($role_desc)"
    continue
  fi

  # 检查 profile 是否已存在
  if hermes profile list 2>/dev/null | grep -q "^$role_name$"; then
    log "跳过（已存在）：$role_name"
    continue
  fi

  log "创建 profile: $role_name"

  # 创建 profile（不绑定 skills，避免冲突）
  if ! hermes profile create "$role_name" --description "$role_desc" --no-skills 2>/dev/null; then
    warn "创建失败：$role_name（可能已存在）"
    continue
  fi

  # 复制角色定义到 profiles/<name>/AGENT.md
  profile_dir="$HERMES_HOME/profiles/$role_name"
  mkdir -p "$profile_dir"
  cp "$role_file" "$profile_dir/AGENT.md"

  # 写 config.yaml（默认 sonnet 模型）
  cat > "$profile_dir/config.yaml" <<EOF
model:
  default: $DEFAULT_MODEL
  provider: anthropic
EOF

done

echo ""
log "完成！已同步 $count 个角色"
echo ""
log "验证：hermes profile list"