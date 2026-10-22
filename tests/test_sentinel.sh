#!/usr/bin/env bash
# test_sentinel.sh — 哨兵核心测试（T-KIT-P3A §2.3）
#
# 照抄 tests/test_dispatch_guards.sh 的 FAKE_CLAUDE 做法：假执行器经 CLAUDE_BIN
# 注入 dispatch-lane.sh（哨兵 → 派单器 → 假 claude），绝不真调 claude。
# 自建一次性看板（kit-p3-selftest-$$ 随机后缀），结束归档清理。
#
# 6 个场景、8 个断言：
#   S1 --dry-run 不写 state、不改卡状态
#   S2 空 assignee 的 ready 卡不派（WOULD_DISPATCH 里不出现）
#   S3 cc- 卡会派（假执行器被调用，fake-claude.calls 里有该 tid）
#   S4 冷却生效（确定性预置）：新卡预置 cooldown[tid]=now+9999 → SKIP cooldown；
#     另断言 SKIP <S3> claimed（claimed 卡必须打印——静默跳过是排错盲区）
#   S5 熔断生效：fails[tid]=3 预置 → 卡被 block 且输出 fused
#   S6 并发上限：WF_MAX_CONCURRENT=1 且已有一张 running 卡 → SKIP global-limit
#
# ⚠ 路径铁律（本项目踩过 3 次）：传给原生程序（python/git/假执行器内的 git）的
# 路径必须 C:/x/y 形态；MSYS 的 /c/x/y 原生 git 报 fatal。全部经 cygpath -m
# （无则 wf_common.native_path）转换。hermes CLI 自身对路径形态不敏感。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TEST_BOARD="kit-p3-selftest-$$"
TMP="$ROOT/.test-tmp/sentinel"
CALL_LOG="$TMP/fake-claude.calls"
# STATE 用 MSYS 形式（bash 的 rm -f 用）；STATE_NATIVE 是原生形态（传给
# 原生 python 的 --state / seed_state 用）。铁律 1：/c/... 直接传给原生
# python 会被当成 C:\c\... 写到别处——第一次实测 S3 因此"真派未写 state"。
STATE="$TMP/sentinel_state.json"
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
HERMES_BIN="$(command -v hermes || echo hermes)"

native_of() {
  if command -v cygpath &>/dev/null; then
    cygpath -m "$1"
  else
    "$PY" - "$1" <<'PYEOF'
import sys, os
sys.path.insert(0, os.path.join("scripts"))
import wf_common
print(wf_common.native_path(sys.argv[1]))
PYEOF
  fi
}
STATE_NATIVE="$(native_of "$STATE")"

# ── 假执行器：记录参数 + 提示词里 TASK.md 的内容（含任务卡号）──
FAKE_CLAUDE="$TMP/fake-claude.sh"
cat > "$FAKE_CLAUDE" <<'FAKEEOF'
#!/usr/bin/env bash
# 假 claude：把调用参数追加到 $FAKE_CLAUDE_CALLS。dispatch-lane.sh 以
#   $CLAUDE_BIN -p "读 <tmpdir>/TASK.md 并执行。..." ...
# 调用，提示词里只有 TASK.md 路径——把该文件内容（含"## 任务卡 t_xxx"段）
# 一并记进调用记录，S3 才能断言"calls 里有该 tid"。
set -u
echo "ARGS: $*" >> "${FAKE_CLAUDE_CALLS:?FAKE_CLAUDE_CALLS 未设置}"
if [[ "${2:-}" =~ ([^[:space:]]*TASK\.md) && -f "${BASH_REMATCH[1]}" ]]; then
  echo "TASK_MD: $(cat "${BASH_REMATCH[1]}")" >> "$FAKE_CLAUDE_CALLS"
fi
exit 0
FAKEEOF
chmod +x "$FAKE_CLAUDE"

# ── 前置：一次性看板 ──
setup_env() {
  hermes kanban boards create "$TEST_BOARD" >/dev/null 2>&1 || true
  export FAKE_CLAUDE_CALLS="$CALL_LOG"
  : > "$CALL_LOG"
}

cleanup_env() {
  hermes kanban boards rm "$TEST_BOARD" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  rmdir "$ROOT/.test-tmp" 2>/dev/null || true
}
trap cleanup_env EXIT

# 建卡：--assignee 可选；stdout = 卡号
new_card() {
  local title="$1" assignee="${2:-}"
  if [[ -n "$assignee" ]]; then
    hermes kanban --board "$TEST_BOARD" create "$title" --assignee "$assignee" 2>/dev/null | awk '{print $2}'
  else
    hermes kanban --board "$TEST_BOARD" create "$title" 2>/dev/null | awk '{print $2}'
  fi
}

card_status() {
  hermes kanban --board "$TEST_BOARD" show "$1" 2>/dev/null \
    | sed -n 's/^  status:[[:space:]]*//p' | head -1 | tr -d '[:space:]'
}

# 哨兵一轮：STATE_NATIVE/CLAUDE_BIN 等已注入；stdout+stderr 都回到调用方
run_sentinel() {
  CLAUDE_BIN="$FAKE_CLAUDE" WF_BOARD="$TEST_BOARD" WF_PYTHON="$PY" WF_HERMES="$HERMES_BIN" \
    "$PY" scripts/card-sentinel.py --state "$STATE_NATIVE" "$@" 2>&1
}

# 预置 state（JSON 写盘）：$1 = tid，$2 = fails，$3 = cooldown 绝对时刻。
# 铁律 1 的另一半：这里传的原生 python 要求 C:/ 形态，必须用 STATE_NATIVE；
# 传 $STATE（MSYS /c/...）会写到 C:\c\... 错误位置 → 哨兵读不到 fails
# → 熔断静默不触发（第一次实测 S5 因此 "缺 fused"）。
seed_state() {
  "$PY" - "$STATE_NATIVE" "$1" "$2" "$3" <<'PYEOF'
import json, sys, os
path, tid, fails, cool = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
st = {"updated_at": "seed", "pid": 0, "board": "seed",
      "cooldown": {tid: cool}, "fails": {tid: fails}, "dispatched_total": 0}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(st, fh)
PYEOF
}

echo "══ 哨兵核心测试（板：$TEST_BOARD）══"
setup_env

# ── S1：--dry-run 不写 state、不改卡状态 ──
echo "── S1 dry-run 不写 state、不改卡 ──"
S1=$(new_card "S1 dry-run 卡" "cc-lane")
rm -f "$STATE"
OUT=$(run_sentinel --dry-run)
S1_ST=$(card_status "$S1")
if [[ ! -e "$STATE" ]]; then ok "S1 dry-run 未写 state（文件不存在）"; else bad "S1 dry-run 写了 state！内容：$(cat "$STATE")"; fi
if [[ "$S1_ST" == "ready" ]]; then ok "S1 卡仍 ready（dry-run 不动卡）"; else bad "S1 卡状态被改：$S1_ST"; fi
if echo "$OUT" | grep -q "^WOULD_DISPATCH $S1 "; then ok "S1 dry-run 打印 WOULD_DISPATCH"; else bad "S1 缺 WOULD_DISPATCH：$OUT"; fi

# ── S2：空 assignee 的 ready 卡不派 ──
echo "── S2 空 assignee 不派 ──"
S2=$(new_card "S2 无主卡")
OUT=$(run_sentinel --dry-run)
if echo "$OUT" | grep -q "WOULD_DISPATCH $S2 "; then
  bad "S2 空 assignee 卡出现在 WOULD_DISPATCH！"
else
  ok "S2 空 assignee 卡不在 WOULD_DISPATCH"
fi
if echo "$OUT" | grep -q "^SKIP $S2 assignee-not-lane"; then ok "S2 记 SKIP assignee-not-lane"; else bad "S2 缺 assignee-not-lane：$OUT"; fi

# ── S3：cc- 卡会派（假执行器被调用，calls 里有 tid）──
echo "── S3 cc- 卡真派 ──"
S3=$(new_card "S3 真派卡" "cc-lane")
: > "$CALL_LOG"
OUT=$(run_sentinel)
if grep -q "$S3" "$CALL_LOG"; then ok "S3 假执行器被调用且 calls 含 $S3"; else bad "S3 calls 缺 $S3：$(cat "$CALL_LOG" | head -3)"; fi
# 真派（非 dry-run）会写 state
if [[ -e "$STATE" ]]; then ok "S3 真派写 state"; else bad "S3 真派未写 state"; fi

# ── S4：冷却生效（确定性预置，不再依赖上一轮 block→unblock 回摆）──
echo "── S4 冷却生效 + claimed 可见 ──"
# 旧做法（unblock S3 靠回摆）会被 claim_* 未释放卡住：卡非 ready 时哨兵判定
# 断链不稳定。改成和 S5 一样的确定性预置：新卡 + cooldown[tid]=now+9999。
# S4 用独立看板（板上只建这一张 cc-lane 卡）：排除同板其它 cc-lane 卡先被
# agent-busy / assignee-not-lane 判定、把 SKIP <S4> cooldown 挤出输出的干扰。
S4_BOARD="kit-p3-selftest-cd-$$"
hermes kanban boards create "$S4_BOARD" >/dev/null 2>&1 || true
S4_RAW=$(hermes kanban --board "$S4_BOARD" create "S4 冷却卡" --assignee cc-lane 2>&1)
S4=$(printf '%s' "$S4_RAW" | awk '{print $2}')
if [[ "$S4" == t_* ]]; then
  : # 卡号正常
else
  bad "S4 建卡失败（卡号=<$S4>）原始输出：$S4_RAW"
fi
seed_state "$S4" 0 $(( $(date +%s) + 9999 ))
# 冷却断言用独立板跑（helper 硬编码 WF_BOARD=$TEST_BOARD，故内联）；显式放宽
# 并发上限，进一步排除并发判定吞输出的可能。
OUT=$(CLAUDE_BIN="$FAKE_CLAUDE" WF_BOARD="$S4_BOARD" WF_PYTHON="$PY" WF_HERMES="$HERMES_BIN" \
  WF_MAX_CONCURRENT=2 WF_MAX_PER_AGENT=2 \
  "$PY" scripts/card-sentinel.py --state "$STATE_NATIVE" 2>&1)
if echo "$OUT" | grep -q "^SKIP $S4 cooldown"; then ok "S4 预置冷却 → SKIP cooldown"; else bad "S4 缺 cooldown：$OUT"; fi
hermes kanban boards rm "$S4_BOARD" >/dev/null 2>&1 || true
# claimed 可见性：把 S3 重新置为 running（unblock 回 ready 后 claim），验证
# 哨兵对 claimed 卡必打印 SKIP <tid> claimed（bug2 的可见性修复）。
# 这条保持在原板逻辑里（S3 在 TEST_BOARD 上），单独跑一轮哨兵。
hermes kanban --board "$TEST_BOARD" unblock "$S3" >/dev/null 2>&1 || true
S3_CLAIMED=0
hermes kanban --board "$TEST_BOARD" claim "$S3" --ttl 7200 >/dev/null 2>&1 && S3_CLAIMED=1
OUT=$(WF_MAX_CONCURRENT=2 WF_MAX_PER_AGENT=2 run_sentinel)
if [[ "$S3_CLAIMED" == "1" ]]; then
  if echo "$OUT" | grep -q "^SKIP $S3 claimed"; then ok "S4 claimed 卡打印 SKIP claimed"; else bad "S4 缺 SKIP $S3 claimed：$OUT"; fi
else
  echo "  (跳过：S3 重新 claim 未成功，环境不可判定，claimed 可见性未验证)"
fi

# ── S5：熔断生效（fails[tid]=3 预置 → block + fused）──
echo "── S5 熔断生效 ──"
S5=$(new_card "S5 熔断卡" "cc-lane")
seed_state "$S5" 3 0
OUT=$(run_sentinel)
S5_ST=$(card_status "$S5")
if echo "$OUT" | grep -q "^SKIP $S5 fused"; then ok "S5 输出 fused"; else bad "S5 缺 fused：$OUT"; fi
if [[ "$S5_ST" == "blocked" ]]; then ok "S5 卡被 block（needs_input）"; else bad "S5 卡未 block：$S5_ST"; fi

# ── S6：并发上限（WF_MAX_CONCURRENT=1 且已有一张 running 卡）──
echo "── S6 全局并发上限 ──"
S6A=$(new_card "S6 占坑卡")
hermes kanban --board "$TEST_BOARD" claim "$S6A" --ttl 7200 >/dev/null 2>&1
S6B=$(new_card "S6 排队卡" "cc-lane")
rm -f "$STATE"
OUT=$(WF_MAX_CONCURRENT=1 run_sentinel)
S6_ST=$(card_status "$S6B")
if echo "$OUT" | grep -q "SKIP global-limit"; then ok "S6 SKIP global-limit"; else bad "S6 缺 global-limit：$OUT"; fi
if [[ "$S6_ST" == "ready" ]]; then ok "S6 排队卡保持 ready（未派）"; else bad "S6 排队卡被动了：$S6_ST"; fi

echo ""
echo "═══ 结果：$PASS 通过 / $FAIL 失败 ═══"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
