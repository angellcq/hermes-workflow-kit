#!/usr/bin/env bash
# test_watchdog_signals.sh — watchdog 新增信号测试（T-KIT-P3B §2.2）
#
# 纯离线：不依赖真哨兵、不依赖网络。4 条断言：
#   W1 state 文件不存在            → 输出含 SENTINEL_DEAD no-state
#   W2 state 文件 mtime 1 小时前    → 输出含 SENTINEL_DEAD age=
#   W3 state 文件刚写              → 不出现 SENTINEL_DEAD
#   W4 ready 卡 assignee 为空 → 含 ASSIGNEE_DRIFT <tid> empty；cc-x 卡 → 不出现
#
# ⚠ 路径形态陷阱（实测踩过）：传给原生程序（python）的路径必须 C:/... 形式，
# 测试里组装路径先过 cygpath -m。watchdog 通过 WF_STATE_FILE 环境变量接受
# 任意 state 路径（指向临时目录，不碰真哨兵的 logs/sentinel_state.json）。
#
# W4 用一次性看板（kit-p3-wd-<pid>）建两张卡，跑完 hermes kanban boards rm 清理，
# 不碰 hermes-kit 等正式板的任何卡。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TEST_BOARD="kit-p3-wd-$$"
TMP="$ROOT/.test-tmp/wd"
mkdir -p "$TMP"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

find_py() {
  if command -v python &>/dev/null; then command -v python
  elif command -v python3 &>/dev/null; then command -v python3
  else echo ""; fi
}
PY=$(find_py)

# watchdog 脚本路径：传给原生 python 的必须是原生形态（cygpath -m）
WD_SCRIPT="$(cygpath -m "$ROOT/scripts/kanban-watchdog.py" 2>/dev/null \
  || echo "$ROOT/scripts/kanban-watchdog.py")"
# state 文件路径同样归一（watchdog 读环境变量后用 pathlib 打开）
STATE_FILE="$(cygpath -m "$TMP/state.json" 2>/dev/null || echo "$TMP/state.json")"

# 统一跑法：WF_STATE_FILE 指临时目录，隔离真哨兵状态
run_wd() {
  WF_STATE_FILE="$STATE_FILE" "$PY" "$WD_SCRIPT" --board "$TEST_BOARD" 2>&1
}

cleanup_env() {
  hermes kanban boards rm "$TEST_BOARD" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  rmdir "$ROOT/.test-tmp" 2>/dev/null || true
}
trap cleanup_env EXIT

echo "══ watchdog 新信号测试（板：$TEST_BOARD）══"

# ── W1：state 文件不存在 → SENTINEL_DEAD no-state ──
echo "── W1 无 state 文件 ──"
rm -f "$STATE_FILE"
OUT=$(run_wd)
if echo "$OUT" | grep -q "SENTINEL_DEAD no-state"; then
  ok "W1 输出含 SENTINEL_DEAD no-state"
else
  bad "W1 缺 SENTINEL_DEAD no-state；输出：$OUT"
fi

# ── W2：state 文件 mtime 1 小时前 → SENTINEL_DEAD age= ──
echo "── W2 state 文件过期（1 小时前）──"
echo '{"touched_by":"test"}' > "$STATE_FILE"
touch -d '-1 hour' "$STATE_FILE"
OUT=$(run_wd)
if echo "$OUT" | grep -q "SENTINEL_DEAD age="; then
  ok "W2 输出含 SENTINEL_DEAD age="
else
  bad "W2 缺 SENTINEL_DEAD age=；输出：$OUT"
fi

# ── W3：state 文件刚写 → 不出现 SENTINEL_DEAD ──
echo "── W3 state 文件新鲜 ──"
echo '{"touched_by":"test"}' > "$STATE_FILE"
OUT=$(run_wd)
if echo "$OUT" | grep -q "SENTINEL_DEAD"; then
  bad "W3 不应出现 SENTINEL_DEAD；输出：$OUT"
else
  ok "W3 新鲜 state 无 SENTINEL_DEAD"
fi

# ── W4：ready 卡 assignee 漂移判据 ──
echo "── W4 ready 卡 assignee 判据（一次性看板自建自清）──"
hermes kanban boards create "$TEST_BOARD" >/dev/null 2>&1 || true
# 卡 A：assignee 为空（缺省建卡）
TID_A=$(hermes kanban --board "$TEST_BOARD" create "W4 漂移卡（无 assignee）" 2>/dev/null \
  | awk '/^Created /{print $2}')
# 卡 B：assignee = cc-x（哨兵前缀，应放行）
TID_B=$(hermes kanban --board "$TEST_BOARD" create "W4 正常卡（cc-x）" --assignee cc-x 2>/dev/null \
  | awk '/^Created /{print $2}')
OUT=$(run_wd)
if [[ -n "$TID_A" ]] && echo "$OUT" | grep -q "ASSIGNEE_DRIFT $TID_A empty"; then
  ok "W4a 空 assignee 卡报 ASSIGNEE_DRIFT $TID_A empty"
else
  bad "W4a 期望 ASSIGNEE_DRIFT $TID_A empty；输出：$OUT"
fi
if [[ -n "$TID_B" ]] && ! echo "$OUT" | grep -q "ASSIGNEE_DRIFT $TID_B"; then
  ok "W4b cc-x 卡不报 ASSIGNEE_DRIFT"
else
  bad "W4b cc-x 卡不应报 ASSIGNEE_DRIFT；输出：$OUT"
fi

echo ""
echo "═══ 结果：$PASS 通过 / $FAIL 失败 ═══"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
