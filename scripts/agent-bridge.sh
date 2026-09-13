#!/usr/bin/env bash
# Hermes Agent Bridge — 多 Agent 桥接脚本（融合版 v4.0）
# 统一封装 claude/codex 调用，支持 Print 模式、后台运行、批量并行。
#
# Usage:
#   bash agent-bridge.sh roles
#   bash agent-bridge.sh claude <role> "<task>" [--workdir <dir>] [--max-turns N]
#   bash agent-bridge.sh claude-bg <role> "<task>" --task-id <id> [--workdir <dir>]
#   bash agent-bridge.sh codex <role> "<task>"
#   bash agent-bridge.sh parallel --tasks tasks.yaml [--dry-run]   # 转为原生看板卡
#   bash agent-bridge.sh monitor --task-id <id>
#   bash agent-bridge.sh list
#   bash agent-bridge.sh kill --task-id <id>

set -euo pipefail

# ════════════════════════════════════════════════════════════════
# 全局配置
# ════════════════════════════════════════════════════════════════

# 自定位项目根：脚本部署在 <项目>/.hermes/scripts/，上级即 .hermes/ 根
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$(dirname "$SCRIPT_DIR")}"

# 角色库定位：CLAUDE_AGENTS_DIR 显式指定优先；否则**自定位优先于继承的 HERMES_HOME**。
# 原因：Hermes CLI/Studio 会话里 HERMES_HOME 恒被导出（指向全局 home），若直接拿它
# 拼路径会解析到全局角色库并报「未发现任何角色」——明明项目 .hermes/通用角色库 就在旁边。
# 因此按「存在的那个」择优，两边都不存在时退回脚本同级目录（供告警复现）。
if [[ -z "${CLAUDE_AGENTS_DIR:-}" ]]; then
  for _cand in "$HERMES_HOME/通用角色库" "$(dirname "$SCRIPT_DIR")/通用角色库"; do
    if [[ -d "$_cand" ]] && compgen -G "$_cand/*.md" >/dev/null 2>&1; then
      CLAUDE_AGENTS_DIR="$_cand"
      break
    fi
  done
  CLAUDE_AGENTS_DIR="${CLAUDE_AGENTS_DIR:-$(dirname "$SCRIPT_DIR")/通用角色库}"
fi
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
# 公共工具：TASK.md 写入（B2：cmd_claude / cmd_claude_bg 共用）
# ════════════════════════════════════════════════════════════════

# 用法：write_task_md <输出路径> <role> <task> <workdir> [task_id]
write_task_md() {
  local task_md="$1" role="$2" task="$3" workdir="$4" task_id="${5:-}"
  {
    echo "# 任务"
    echo ""
    echo "$task"
    echo ""
    echo "## 角色"
    echo "$role"
    echo ""
    echo "## 工作目录"
    echo "${workdir:-$(pwd)}"
    if [[ -n "$task_id" ]]; then
      echo ""
      echo "## 任务 ID"
      echo "$task_id"
    fi
  } > "$task_md"
}

# ════════════════════════════════════════════════════════════════
# 公共工具：JSON 输出（A3：--json 机器可读契约）
# ════════════════════════════════════════════════════════════════

# 取可用的 JSON 处理器：jq 优先，python 兜底；都没有返回 1
_json_bin() {
  if command -v jq &>/dev/null; then echo "jq"; return 0; fi
  if command -v python3 &>/dev/null; then echo "python3"; return 0; fi
  if command -v python &>/dev/null; then echo "python"; return 0; fi
  return 1
}

# 把 "name<TAB>desc" 行流转为 JSON 数组 [{name, description}]
_lines_to_roles_json() {
  local bin
  bin=$(_json_bin) || { err "--json 需要 jq 或 python"; return 1; }
  if [[ "$bin" == "jq" ]]; then
    jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], description: .[1]})'
  else
    "$bin" -c '
import json, sys
rows = [l.split("\t", 1) for l in sys.stdin.read().splitlines() if l.strip()]
print(json.dumps([{"name": r[0], "description": r[1] if len(r) > 1 else ""} for r in rows], ensure_ascii=False, indent=2))
'
  fi
}

# ════════════════════════════════════════════════════════════════
# 并发锁（E1：update_active 的 active.json 读写互斥）
# ════════════════════════════════════════════════════════════════

# mkdir 原子锁（flock 在 MSYS/Windows 不一定可用，mkdir 全平台原子）
acquire_lock() {
  local lockdir="$1" i
  for i in $(seq 1 100); do
    if mkdir "$lockdir" 2>/dev/null; then return 0; fi
    # 清理 30s 以上的死锁（持有者崩溃残留）
    if [[ -d "$lockdir" ]] && [[ -n "$(find "$lockdir" -maxdepth 0 -mmin +0.5 2>/dev/null)" ]]; then
      rmdir "$lockdir" 2>/dev/null || true
    fi
    sleep 0.1
  done
  return 1
}

release_lock() { rmdir "$1" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════════
# 角色库
# ════════════════════════════════════════════════════════════════

# 角色库：动态扫描 $CLAUDE_AGENTS_DIR/*.md 的 frontmatter（name/description）。
# 唯一事实源 = 仓库 通用角色库/*.md（部署到 .hermes/通用角色库/）。
# 新增角色只需：新增 .md → cp 到 .hermes/通用角色库/ → 无需改本脚本。
load_roles() {
  # 惰性调用（在 cmd_roles / check_role 内）：脚本被 source 或执行其它子命令时
  # 不应因角色库解析结果而打印误导性告警
  ROLES=()
  ROLE_DESC=()
  local f name desc
  for f in "$CLAUDE_AGENTS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    name=$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1)
    [[ -z "$name" ]] && name=$(basename "$f" .md)
    desc=$(sed -n 's/^description:[[:space:]]*//p' "$f" | head -1)
    # 兼容 description: |（YAML 块格式）：取块内首个非空行
    if [[ -z "$desc" || "$desc" == "|" || "$desc" == ">" ]]; then
      desc=$(sed -n '/^description:[[:space:]]*[|>]/,/^[[:alpha:]_]*:/p' "$f" | sed -n '2p' | sed 's/^[[:space:]]*//')
    fi
    desc=${desc#\"}; desc=${desc%\"}
    ROLES+=("$name")
    ROLE_DESC+=("${desc:0:60}")
  done
  if [[ ${#ROLES[@]} -eq 0 ]]; then
    warn "未在 $CLAUDE_AGENTS_DIR 发现任何角色 .md（先运行 sync-roles-to-profiles.sh 部署）"
  fi
}

cmd_roles() {
  local as_json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) as_json=true; shift ;;
      *) err "未知参数：$1"; return 1 ;;
    esac
  done

  load_roles

  if $as_json; then
    local i
    for i in "${!ROLES[@]}"; do
      printf '%s\t%s\n' "${ROLES[$i]}" "${ROLE_DESC[$i]}"
    done | _lines_to_roles_json
    return $?
  fi

  echo "═══ 可用角色库（${#ROLES[@]} 个）═══"
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
  load_roles
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
  write_task_md "$task_md" "$role" "$task" "$workdir" "$task_id"

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
  # E1：active.json 读改写必须互斥，防止并发 claude-bg 互相覆盖
  local lockdir="$ACTIVE_FILE.lock"
  if ! acquire_lock "$lockdir"; then
    err "active.json 锁等待超时（可能有进程持有锁超过 10s）"
    return 1
  fi
  _update_active_locked "$@"
  local rc=$?
  release_lock "$lockdir"
  return $rc
}

_update_active_locked() {
  local task_id="$1" role="$2" pid="$3" status="$4"

  # pid 只接受纯数字；空/非法一律归零。否则 jq 的 tonumber / python 的 int("") 会抛错，
  # 导致 active.json 静默不更新（实测：kill 空 pid 任务时状态直接丢失）
  [[ "$pid" =~ ^[0-9]+$ ]] || pid=0

  if [[ -f "$ACTIVE_FILE" ]]; then
    local active
    active=$(cat "$ACTIVE_FILE")
  else
    active='{"tasks":[]}'
  fi

  # jq 优先；无 jq 用 python 兜底（两者皆无则报错退出，绝不静默丢数据）。
  # python 路径：代码走 -c，JSON 走 stdin/stdout，文件读写由 bash 重定向完成
  # （避免 Windows Python 收到 MSYS 路径 /tmp/... 时写到错误位置）
  if command -v jq &>/dev/null; then
    local tmp
    tmp=$(mktemp)
    echo "$active" | jq --arg id "$task_id" --arg role "$role" --arg pid "$pid" --arg status "$status" \
      '.tasks |= map(select(.task_id != $id)) + [{task_id: $id, role: $role, pid: ($pid | tonumber), status: $status, updated_at: now | strftime("%Y-%m-%dT%H:%M:%S%z")}]' \
      > "$tmp"
    mv "$tmp" "$ACTIVE_FILE"
  else
    local py_bin=""
    command -v python3 &>/dev/null && py_bin="python3"
    [[ -z "$py_bin" ]] && command -v python &>/dev/null && py_bin="python"
    if [[ -n "$py_bin" ]]; then
      local tmp
      tmp=$(mktemp)
      printf '%s' "$active" | "$py_bin" -c '
import json, sys, datetime
task_id, role, pid, status = sys.argv[1:5]
try:
    data = json.load(sys.stdin)
except Exception:
    data = {"tasks": []}
data.setdefault("tasks", [])
data["tasks"] = [t for t in data["tasks"] if t.get("task_id") != task_id]
data["tasks"].append({
    "task_id": task_id, "role": role,
    "pid": int(pid) if str(pid).strip().isdigit() else 0,
    "status": status,
    "updated_at": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S%z"),
})
json.dump(data, sys.stdout, ensure_ascii=False, indent=2)
' "$task_id" "$role" "$pid" "$status" > "$tmp" && mv "$tmp" "$ACTIVE_FILE"
    else
      err "active.json 更新失败：需要 jq 或 python（两者都未安装）"
      return 1
    fi
  fi
}

# ════════════════════════════════════════════════════════════════
# 监控
# ════════════════════════════════════════════════════════════════

cmd_monitor() {
  local task_id="" as_json=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) task_id="$2"; shift 2 ;;
      --json) as_json=true; shift ;;
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

  if $as_json; then
    # status.json 原文即契约；附带日志尾部作为 log_tail 字段。
    # 数据全部走 stdin/argv（不走路径 argv）——Windows Python 无法识别 MSYS 路径。
    local bin log_tail
    bin=$(_json_bin) || { err "--json 需要 jq 或 python"; return 1; }
    log_tail=$(tail -n 30 "$task_dir/claude.log" 2>/dev/null || true)
    if [[ "$bin" == "jq" ]]; then
      jq --arg log "$log_tail" '. + {log_tail: $log}' "$task_dir/status.json"
    else
      cat "$task_dir/status.json" | "$bin" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
data["log_tail"] = sys.argv[1]
print(json.dumps(data, ensure_ascii=False, indent=2))
' "$log_tail"
    fi
    return $?
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
  local as_json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) as_json=true; shift ;;
      *) err "未知参数：$1"; return 1 ;;
    esac
  done

  if $as_json; then
    local bin
    bin=$(_json_bin) || { err "--json 需要 jq 或 python"; return 1; }
    if [[ -d "$TASK_BASE" ]]; then
      # 各任务的 status.json 合并为数组（内容走 stdin，规避 MSYS 路径问题）
      if [[ "$bin" == "jq" ]]; then
        find "$TASK_BASE" -mindepth 2 -maxdepth 2 -name status.json -exec cat {} + 2>/dev/null \
          | jq -s '.'
      else
        find "$TASK_BASE" -mindepth 2 -maxdepth 2 -name status.json -exec cat {} + 2>/dev/null \
          | "$bin" -c '
import json, sys
buf = sys.stdin.read()
dec = json.JSONDecoder()
items, idx = [], 0
while idx < len(buf):
    while idx < len(buf) and buf[idx] not in "{":
        idx += 1
    if idx >= len(buf):
        break
    try:
        obj, end = dec.raw_decode(buf, idx)
        items.append(obj)
        idx = end
    except json.JSONDecodeError:
        idx += 1
print(json.dumps(items, ensure_ascii=False, indent=2))
'
      fi
    else
      echo "[]"
    fi
    return 0
  fi

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

  # 空/非数字 PID 是合法情况（进程已退出、登记失败）：只更新状态，绝不把 "" 传给
  # update_active（会让 jq tonumber / python int() 抛错，导致 active.json 静默不更新）
  local pid
  pid=$(tr -dc '0-9' < "$task_dir/pid" 2>/dev/null || true)

  if [[ -z "$pid" ]]; then
    warn "任务 $task_id 无有效 PID（进程可能已退出），仅更新状态"
  else
    log "终止任务 $task_id (PID=$pid)"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      sleep 2
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid"
        warn "强制终止 PID=$pid"
      fi
    else
      log "PID=$pid 已不存在，仅更新状态"
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
  # 路线 A：批量并行不再由本脚本自己 fork `claude -p` 并维护 active.json，
  # 而是把一批任务转成**平台原生看板卡**，交 dispatcher 认领执行。
  # 三道闸门在 kanban-dispatch.py 里：环境(preflight) → 边界互斥(scope-check)
  # → 语义指纹幂等(--idempotency-key)。本函数只做入口转发，保持 CLI 兼容。
  local py_bin=""
  command -v python3 &>/dev/null && py_bin="python3"
  [[ -z "$py_bin" ]] && command -v python &>/dev/null && py_bin="python"
  if [[ -z "$py_bin" ]]; then
    err "parallel 需要 python（解析 tasks.yaml + 执行三道闸门）"
    return 1
  fi

  local dispatcher="$SCRIPT_DIR/kanban-dispatch.py"
  if [[ ! -f "$dispatcher" ]]; then
    err "未找到 kanban-dispatch.py（应与本脚本同目录）"
    return 1
  fi

  # 路径翻译：原生 python 不认 MSYS 路径（/d/... 会被拼成 D:\d\...）
  if command -v cygpath &>/dev/null; then
    dispatcher=$(cygpath -w "$dispatcher")
  fi

  "$py_bin" "$dispatcher" "$@"
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
    echo "  bash agent-bridge.sh roles [--json]"
    echo "  bash agent-bridge.sh claude <role> \"<task>\" [--workdir DIR] [--max-turns N]"
    echo "  bash agent-bridge.sh claude-bg <role> \"<task>\" --task-id <id>"
    echo "  bash agent-bridge.sh codex <role> \"<task>\""
    echo "  bash agent-bridge.sh parallel --tasks <yaml>"
    echo "  bash agent-bridge.sh monitor --task-id <id> [--json]"
    echo "  bash agent-bridge.sh list [--json]"
    echo "  bash agent-bridge.sh kill --task-id <id>"
    exit 1
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    roles)       cmd_roles "$@" ;;
    claude)      cmd_claude "$@" ;;
    claude-bg)   cmd_claude_bg "$@" ;;
    codex)       cmd_codex "$@" ;;
    parallel)    cmd_parallel "$@" ;;
    monitor)     cmd_monitor "$@" ;;
    list)        cmd_list "$@" ;;
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

# 仅直接执行时进入主流程；被 source（测试）时不触发
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi