#!/usr/bin/env bash
# Hermes Preflight — 派发前环境与调度存活闸门（v4.4.2）
#
# 为什么需要它：套件把「看板为事实源 + dispatcher 自动认领」写进了制度层，但
# dispatcher 默认跑在 gateway 进程里；gateway 没在跑时看板不会被认领、cron 不触发，
# 而套件此前**没有任何检查**（实测本机 gateway 长期未运行，无人发现）。
# 本脚本是 S4 派发的准入检查，也是「调度中心宕机」的检测点。
#
# 用法：
#   bash .hermes/scripts/preflight.sh             # 人读输出
#   bash .hermes/scripts/preflight.sh --json      # 机器可读
#   bash .hermes/scripts/preflight.sh --require-dispatcher   # 严格模式：无调度器即拒发
# 退出码：0 = READY；1 = DEGRADED（只能串行 + 人工对账）；2 = NOT READY

set -uo pipefail   # 故意不用 -e：单项失败要继续跑完并汇总

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_DIR="$(dirname "$SCRIPT_DIR")"
ROLES_DIR="${CLAUDE_AGENTS_DIR:-$HERMES_DIR/通用角色库}"
BRIDGE="$SCRIPT_DIR/agent-bridge.sh"

AS_JSON=false
QUIET=false
REQUIRE_DISPATCHER=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) AS_JSON=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --require-dispatcher) REQUIRE_DISPATCHER=true; shift ;;
    -h|--help)
      echo "用法：bash preflight.sh [--json] [--quiet] [--require-dispatcher]"
      echo "  --require-dispatcher  无调度器时判为 NOT READY（退出码 2），而非 DEGRADED"
      exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

FAIL=0      # 硬失败 → NOT READY
WARN=0      # 降级项 → DEGRADED
declare -a LINES=()
declare -a ITEMS=()

# python 解析器（§3 的 gateway_state.json 兜底与 §4 都依赖，故提前确定）
PY=""
command -v python3 &>/dev/null && PY="python3"
[[ -z "$PY" ]] && command -v python &>/dev/null && PY="python"

record() {  # record <level: ok|warn|fail> <名称> <详情>
  local level="$1" name="$2" detail="${3:-}"
  case "$level" in
    ok)   LINES+=("  ✓ $name${detail:+ — $detail}") ;;
    warn) LINES+=("  ⚠ $name${detail:+ — $detail}"); WARN=$((WARN + 1)) ;;
    fail) LINES+=("  ✗ $name${detail:+ — $detail}"); FAIL=$((FAIL + 1)) ;;
  esac
  ITEMS+=("$(printf '{"level":"%s","name":"%s","detail":"%s"}' \
    "$level" "$(printf '%s' "$name" | sed 's/"/\\"/g')" \
    "$(printf '%s' "$detail" | sed 's/"/\\"/g')")")
}

# ═══ 1. hermes CLI ═══
if command -v hermes &>/dev/null; then
  record ok "hermes CLI" "$(hermes --version 2>/dev/null | head -1 || echo 可用)"
else
  record fail "hermes CLI" "未安装或不在 PATH（看板/worker 全链路不可用）"
fi

# ═══ 2. 看板可用 ═══
BOARD=""
if command -v hermes &>/dev/null; then
  if BOARD=$(hermes kanban boards 2>/dev/null | awk '/^●/ {print $2; exit}'); then
    if [[ -n "$BOARD" ]]; then
      record ok "看板可读写" "当前板: $BOARD"
    else
      record warn "看板可读写" "未取到当前板名（kanban.db 可能未初始化：hermes kanban init）"
    fi
  else
    record fail "看板可读写" "hermes kanban boards 执行失败"
  fi
fi

# ═══ 3. 调度器（dispatcher）存活 —— 本闸门的核心 ═══
# 判定顺序（抗文案变化）：
#   a. hermes gateway status 明确说进程在跑 → 存活
#   b. gateway_state.json 里 gateway_state=running 且 pid 仍存活 → 存活（兜底）
#   c. pgrep 到独立 kanban daemon → 存活
#   d. 以上都不成立 → 未确认存活
# 注意：早期版本只匹配 "gateway process detected"，而真实正例文案是
# "Gateway process running (PID ...)"、反例才是 "No gateway process detected"，
# 导致 gateway 在跑时被误判为未运行（假阴性，已修）。
DISPATCH="down"
if command -v hermes &>/dev/null; then
  GW_STATUS=$(hermes gateway status 2>&1 || true)
  if printf '%s' "$GW_STATUS" | grep -q "Gateway process running"; then
    DISPATCH="gateway"
  fi
fi
if [[ "$DISPATCH" == "down" && -n "$PY" ]]; then
  GW_STATE=$("$PY" - <<'PYEOF' 2>/dev/null || true
import json, pathlib, os, sys
p = pathlib.Path(os.environ.get("HERMES_HOME", pathlib.Path.home() / "AppData/Local/hermes")) / "gateway_state.json"
if not p.is_file():
    p = pathlib.Path.home() / ".hermes" / "gateway_state.json"
try:
    d = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    sys.exit(0)
if d.get("gateway_state") != "running":
    sys.exit(0)
pid = d.get("pid")
try:
    os.kill(int(pid), 0)
except Exception:
    sys.exit(0)
print("running")
PYEOF
)
  [[ "$GW_STATE" == "running" ]] && DISPATCH="gateway-state"
fi
if [[ "$DISPATCH" == "down" ]]; then
  if command -v pgrep &>/dev/null && pgrep -f 'kanban daemon' &>/dev/null; then
    DISPATCH="daemon"
  fi
fi
if [[ "$DISPATCH" != "down" ]]; then
  record ok "调度器（dispatcher）" "存活（$DISPATCH）"
elif [[ "$REQUIRE_DISPATCHER" == "true" ]]; then
  record fail "调度器（dispatcher）" "未运行：看板不会被认领、cron 不触发 → 本任务禁止并行派发"
else
  record warn "调度器（dispatcher）" \
    "未确认存活（hermes gateway status / gateway_state.json / pgrep 均无正信号）→ 降级为串行 + 人工对账"
fi

# ═══ 4. python（pipeline / scope-check 依赖） ═══
if [[ -n "$PY" ]]; then
  record ok "python" "$PY $("$PY" -c 'import sys;print(".".join(map(str,sys.version_info[:3])))' 2>/dev/null)"
else
  record fail "python" "未找到：pipeline.py / scope-check.py 不可用"
fi

# ═══ 5. 角色库可加载 ═══
if [[ -f "$BRIDGE" ]]; then
  ROLE_COUNT=$(
    env -u HERMES_HOME CLAUDE_AGENTS_DIR="$ROLES_DIR" bash "$BRIDGE" roles 2>/dev/null \
      | grep -cE '^[a-z][a-z-]+[[:space:]]' || true
  )
  if [[ "${ROLE_COUNT:-0}" -gt 0 ]]; then
    record ok "角色库" "$ROLE_COUNT 个角色（$ROLES_DIR）"
  else
    record warn "角色库" "0 个角色：检查 $ROLES_DIR"
  fi
else
  record warn "角色库" "未找到 agent-bridge.sh"
fi

# ═══ 6. scope-check 可用（S4 准出工具） ═══
if [[ -f "$SCRIPT_DIR/scope-check.py" && -n "$PY" ]]; then
  record ok "scope-check.py" "S4 边界互斥校验就绪"
else
  record fail "scope-check.py" "缺失：无法做文件边界互斥校验（并行派发无保护）"
fi

# ═══ 结论 ═══
if [[ "$FAIL" -gt 0 ]]; then VERDICT="NOT_READY"; RC=2
elif [[ "$WARN" -gt 0 ]]; then VERDICT="DEGRADED"; RC=1
else VERDICT="READY"; RC=0
fi

if [[ "$AS_JSON" == "true" ]]; then
  printf '{"verdict":"%s","dispatcher":"%s","fails":%s,"warnings":%s,"checks":[%s]}\n' \
    "$VERDICT" "$DISPATCH" "$FAIL" "$WARN" "$(IFS=,; echo "${ITEMS[*]}")"
else
  if [[ "$QUIET" == "false" ]]; then
    echo "═══ 派发前环境闸门（preflight）═══"
    printf '%s\n' "${LINES[@]}"
    echo "───"
  fi
  case "$VERDICT" in
    READY)     echo "结论: READY —— 可并行派发（调度器存活）" ;;
    DEGRADED)  echo "结论: DEGRADED —— 只能串行派发 + 人工对账（调度器未运行）" ;;
    NOT_READY) echo "结论: NOT READY —— 禁止派发（存在硬失败项）" ;;
  esac
fi
exit "$RC"
