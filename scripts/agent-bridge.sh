#!/usr/bin/env bash
# Hermes Agent Bridge — 多 Agent 桥接脚本（融合版 v4.0）
# 统一封装 claude/codex 调用，支持 Print 模式、后台运行、批量并行。
#
# Usage:
#   bash agent-bridge.sh roles
#   bash agent-bridge.sh claude <role> "<task>" [--workdir <dir>] [--max-turns N]
#   bash agent-bridge.sh claude-bg <role> "<task>" --task-id <id> [--workdir <dir>]
#   bash agent-bridge.sh codex <role> "<task>"
#   bash agent-bridge.sh parallel --tasks tasks.yaml
#   bash agent-bridge.sh monitor --task-id <id>
#   bash agent-bridge.sh list
#   bash agent-bridge.sh kill --task-id <id>

set -euo pipefail

# ════════════════════════════════════════════════════════════════
# 全局配置
# ════════════════════════════════════════════════════════════════

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CLAUDE_AGENTS_DIR="${CLAUDE_AGENTS_DIR:-$HOME/.claude/agents}"
TASK_BASE="${TASK_BASE:-$HOME/.workbuddy/agent-bridge/tasks}"
FAILURES_LOG="${FAILURES_LOG:-$HOME/.workbuddy/agent-bridge/failures.log}"
ACTIVE_FILE="${ACTIVE_FILE:-$HOME/.workbuddy/agent-bridge/active.json}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CODEX_BIN="${CODEX_BIN:-codex}"

mkdir -p "$TASK_BASE"
mkdir -p "$(dirname "$FAILURES_LOG")"
mkdir -p "$(dirname "$ACTIVE_FILE")"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠${NC} $*" >&2; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*" >&2; }

# ════════════════════════════════════════════════════════════════
# 角色库
# ════════════════════════════════════════════════════════════════

# 16 个通用角色（与 ~/.claude/agents/*.md 对应）
ROLES=(
  "backend-developer"
  "frontend-developer"
  "fullstack-developer"
  "mobile-developer"
  "dba"
  "devops"
  "test-engineer"
  "security-reviewer"
  "code-reviewer"
  "architect"
  "planner"
  "project-manager"
  "build-error-resolver"
  "docs-writer"
  "tdd-guide"
  "loop-operator"
)

# 角色描述
ROLE_DESC=(
  "通用后端开发（跨语言自适应）"
  "通用前端开发（Vue/React/小程序自适应）"
  "全栈开发（前后端贯通）"
  "移动端开发（iOS/Android/Flutter/RN）"
  "数据库设计与优化"
  "CI/CD 与部署"
  "测试（单测/集成/E2E）"
  "安全审计"
  "通用代码审查"
  "架构决策"
  "实施计划"
  "PM 拆解/跟踪/风险"
  "构建错误修复"
  "文档生成"
  "TDD 强制方法论"
  "自主 Agent 循环监控"
)

cmd_roles() {
  echo "═══ 可用角色库（$(printf '%s\n' "${ROLES[@]}" | wc -l) 个）═══"
  echo ""
  printf '%-22s %s\n' "ROLE" "DESCRIPTION"
  printf '%-22s %s\n' "────" "───────────"
  for i in "${!ROLES[@]}"; do
    printf '%-22s %s\n' "${ROLES[$i]}" "${ROLE_DESC[$i]}"
  done
  echo ""
  echo "角色定义路径：$CLAUDE_AGENTS_DIR/<role>.md"
}

# 检查角色是否存在
check_role() {
  local role="$1"
  if [[ ! " ${ROLES[*]} " =~ " $role " ]]; then
    err "未知角色：$role"
    err "可用角色：bash agent-bridge.sh roles"
    return 1
  fi

  local role_file="$CLAUDE_AGENTS_DIR/$role.md"
  if [[ ! -f "$role_file" ]]; then
    warn "角色定义文件不存在：$role_file"
    warn "请从仓库的通用角色库说明.md 旁的对应 .md 复制到该路径"
    return 1
  fi
}

# 读取角色提示词
read_role_prompt() {
  local role="$1"
  local role_file="$CLAUDE_AGENTS_DIR/$role.md"
  if [[ -f "$role_file" ]]; then
    cat "$role_file"
  fi
}

# ════════════════════════════════════════════════════════════════
# Print 模式（同步）
# ════════════════════════════════════════════════════════════════

cmd_claude() {
  local role="" task="" workdir="" max_turns=10 allowed_tools="Read,Edit,Write,Bash,Grep"

  if [[ $# -lt 2 ]]; then
    err "用法：bash agent-bridge.sh claude <role> \"<task>\" [--workdir DIR] [--max-turns N]"
    return 1
  fi

  role="$1"
  shift
  task="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workdir)    workdir="$2"; shift 2 ;;
      --max-turns)  max_turns="$2"; shift 2 ;;
      --tools)      allowed_tools="$2"; shift 2 ;;
      *) err "未知参数：$1"; return 1 ;;
    esac
  done

  check_role "$role" || return 1

  # 防空任务：写 TASK.md
  local tmpdir
  tmpdir="$(mktemp -d)"
  local task_md="$tmpdir/TASK.md"
  cat > "$task_md" <<EOF
# 任务

$task

## 角色
$role

## 工作目录
${workdir:-$(pwd)}
EOF

  log "调用 claude -p [role=$role, max_turns=$max_turns]"

  # 调用 claude -p（启动指令只写"读 TASK.md 并执行"，不超过 4KB）
  "$CLAUDE_BIN" -p "读 $task_md 并执行。完成后输出修改文件清单与 diff 摘要。" \
    --allowedTools "$allowed_tools" \
    --max-turns "$max_turns" \
    --output-format json

  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

cmd_codex() {
  local role="" task=""
  if [[ $# -lt 2 ]]; then
    err "用法：bash agent-bridge.sh codex <role> \"<task>\""
    return 1
  fi

  role="$1"
  shift
  task="$1"
  shift

  check_role "$role" || return 1

  log "调用 codex [role=$role]"
  "$CODEX_BIN" --quiet "$task"
}

# ════════════════════════════════════════════════════════════════
# 后台运行
# ════════════════════════════════════════════════════════════════

cmd_claude_bg() {
  local role="" task="" task_id="" workdir="" max_turns=10

  if [[ $# -lt 3 ]]; then
    err "用法：bash agent-bridge.sh claude-bg <role> \"<task>\" --task-id <id>"
    return 1
  fi

  role="$1"
  shift
  task="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id)    task_id="$2"; shift 2 ;;
      --workdir)    workdir="$2"; shift 2 ;;
      --max-turns)  max_turns="$2"; shift 2 ;;
      *) err "未知参数：$1"; return 1 ;;
    esac
  done

  if [[ -z "$task_id" ]]; then
    err "必须指定 --task-id"
    return 1
  fi

  check_role "$role" || return 1

  local task_dir="$TASK_BASE/$task_id"
  mkdir -p "$task_dir"

  # 写 TASK.md
  local task_md="$task_dir/TASK.md"
  cat > "$task_md" <<EOF
# 任务

$task

## 角色
$role

## 工作目录
${workdir:-$(pwd)}

## 任务 ID
$task_id
EOF

  # 写 status.json（启动中）
  cat > "$task_dir/status.json" <<EOF
{
  "task_id": "$task_id",
  "role": "$role",
  "status": "starting",
  "started_at": "$(date -Iseconds)"
}
EOF

  # 后台启动 claude
  log "后台启动 [task_id=$task_id, role=$role]"
  nohup "$CLAUDE_BIN" -p "读 $task_md 并执行。完成后输出修改文件清单与 diff 摘要到 $task_dir/output.txt" \
    --allowedTools "Read,Edit,Write,Bash,Grep" \
    --max-turns "$max_turns" \
    > "$task_dir/claude.log" 2>&1 &

  local pid=$!
  echo "$pid" > "$task_dir/pid"

  # 更新 status
  cat > "$task_dir/status.json" <<EOF
{
  "task_id": "$task_id",
  "role": "$role",
  "status": "running",
  "pid": $pid,
  "started_at": "$(date -Iseconds)"
}
EOF

  # 更新 active.json
  update_active "$task_id" "$role" "$pid" "running"

  echo "Task started: $task_id"
  echo "  PID: $pid"
  echo "  Log: $task_dir/claude.log"
  echo "  Status: $task_dir/status.json"
}

update_active() {
  local task_id="$1" role="$2" pid="$3" status="$4"

  if [[ -f "$ACTIVE_FILE" ]]; then
    local active
    active=$(cat "$ACTIVE_FILE")
  else
    active='{"tasks":[]}'
  fi

  # 简化：用 jq 操作（若可用），否则用 sed
  if command -v jq &>/dev/null; then
    local tmp
    tmp=$(mktemp)
    echo "$active" | jq --arg id "$task_id" --arg role "$role" --arg pid "$pid" --arg status "$status" \
      '.tasks |= map(select(.task_id != $id)) + [{task_id: $id, role: $role, pid: ($pid | tonumber), status: $status, updated_at: now | strftime("%Y-%m-%dT%H:%M:%S%z")}]' \
      > "$tmp"
    mv "$tmp" "$ACTIVE_FILE"
  else
    warn "未安装 jq，active.json 更新降级处理"
  fi
}

# ════════════════════════════════════════════════════════════════
# 监控
# ════════════════════════════════════════════════════════════════

cmd_monitor() {
  local task_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) task_id="$2"; shift 2 ;;
      *) err "未知参数：$1"; return 1 ;;
    esac
  done

  if [[ -z "$task_id" ]]; then
    err "必须指定 --task-id"
    return 1
  fi

  local task_dir="$TASK_BASE/$task_id"
  if [[ ! -d "$task_dir" ]]; then
    err "任务不存在：$task_id"
    return 1
  fi

  echo "═══ 任务监控 [$task_id] ═══"
  echo ""
  echo "─── status.json ───"
  cat "$task_dir/status.json"
  echo ""
  echo "─── claude.log (最后 30 行) ───"
  tail -n 30 "$task_dir/claude.log" 2>/dev/null || echo "(日志文件不存在)"
}

cmd_list() {
  echo "═══ 活跃任务 ═══"
  echo ""
  if [[ -d "$TASK_BASE" ]]; then
    for task_dir in "$TASK_BASE"/*/; do
      [[ ! -d "$task_dir" ]] && continue
      local task_id
      task_id=$(basename "$task_dir")
      if [[ -f "$task_dir/status.json" ]]; then
        local status
        status=$(grep -o '"status": *"[^"]*"' "$task_dir/status.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
        printf '%-20s %s\n' "$task_id" "$status"
      fi
    done
  else
    echo "(无活跃任务)"
  fi
}

cmd_kill() {
  local task_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) task_id="$2"; shift 2 ;;
      *) err "未知参数：$1"; return 1 ;;
    esac
  done

  if [[ -z "$task_id" ]]; then
    err "必须指定 --task-id"
    return 1
  fi

  local task_dir="$TASK_BASE/$task_id"
  if [[ ! -f "$task_dir/pid" ]]; then
    err "任务无 PID 记录：$task_id"
    return 1
  fi

  local pid
  pid=$(cat "$task_dir/pid")
  log "终止任务 $task_id (PID=$pid)"

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid"
      warn "强制终止 PID=$pid"
    fi
  fi

  cat > "$task_dir/status.json" <<EOF
{
  "task_id": "$task_id",
  "status": "killed",
  "killed_at": "$(date -Iseconds)"
}
EOF

  update_active "$task_id" "" "" "killed"
  log "任务 $task_id 已终止"
}

# ════════════════════════════════════════════════════════════════
# 批量并行
# ════════════════════════════════════════════════════════════════

cmd_parallel() {
  local tasks_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tasks) tasks_file="$2"; shift 2 ;;
      *) err "未知参数：$1"; return 1 ;;
    esac
  done

  if [[ -z "$tasks_file" || ! -f "$tasks_file" ]]; then
    err "必须指定有效的 --tasks <yaml 文件>"
    return 1
  fi

  if ! command -v yq &>/dev/null && ! command -v python3 &>/dev/null; then
    err "需要 yq 或 python3 解析 YAML"
    return 1
  fi

  log "解析任务文件：$tasks_file"

  # 简单实现：每个任务起一个 claude-bg
  local task_ids=()
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*(.*) ]]; then
      task_ids+=("${BASH_REMATCH[1]}")
    fi
  done < "$tasks_file"

  warn "简化实现：实际请用 Python pipeline.py 处理批量并行"
  warn "此函数仅作占位，请参考 skills/autonomous-delivery/SKILL.md"

  return 1
}

# ════════════════════════════════════════════════════════════════
# 失败模式记录
# ════════════════════════════════════════════════════════════════

record_failure() {
  local task_id="$1" reason="$2"
  echo "[$(date -Iseconds)] task=$task_id reason=$reason" >> "$FAILURES_LOG"
}

# ════════════════════════════════════════════════════════════════
# 入口
# ════════════════════════════════════════════════════════════════

main() {
  if [[ $# -lt 1 ]]; then
    cmd_roles
    echo ""
    echo "用法："
    echo "  bash agent-bridge.sh roles"
    echo "  bash agent-bridge.sh claude <role> \"<task>\" [--workdir DIR] [--max-turns N]"
    echo "  bash agent-bridge.sh claude-bg <role> \"<task>\" --task-id <id>"
    echo "  bash agent-bridge.sh codex <role> \"<task>\""
    echo "  bash agent-bridge.sh parallel --tasks <yaml>"
    echo "  bash agent-bridge.sh monitor --task-id <id>"
    echo "  bash agent-bridge.sh list"
    echo "  bash agent-bridge.sh kill --task-id <id>"
    exit 1
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    roles)       cmd_roles ;;
    claude)      cmd_claude "$@" ;;
    claude-bg)   cmd_claude_bg "$@" ;;
    codex)       cmd_codex "$@" ;;
    parallel)    cmd_parallel "$@" ;;
    monitor)     cmd_monitor "$@" ;;
    list)        cmd_list ;;
    kill)        cmd_kill "$@" ;;
    -h|--help|help)
      main
      ;;
    *)
      err "未知命令：$cmd"
      echo "运行 'bash agent-bridge.sh roles' 查看帮助"
      exit 1
      ;;
  esac
}

main "$@"