#!/usr/bin/env bash
# verify-deploy.sh 场景测试（T-KIT-P9）
# 用法：bash tests/test_verify_deploy.sh
#
# ⚠ 绝对不许碰真实的 ~/.claude/agents、真实 $HERMES_HOME、真实看板——
#   HERMES_HOME/项目目录/CC agents 全用临时目录伪造；hermes 用 HERMES_BIN 注入的 FAKE 假命令。
# 5 条断言：
#   T1 伪造齐全（11 假角色 + watchdog md5 相同 + SKILL version 同 + 资产 + board/cron list 齐）→ rc=0 且输出含「0 失败」
#   T2 缺 wf.env（V6）→ rc=1，且 V6 FAIL 行带「修法：」
#   T3 所有 FAIL 行必带「修法：」（基线故意缺资产跑一遍）
#   T4 --skip-repo-tests → 输出现 SKIP 且 rc=0（skip 不算失败）
#   T5 汇总行契约：═══ 验收：N 通过 / 0 失败 ══（run_tests 容错注册块按 FAIL 数走 rc）
# 输出契约：═══ 结果：<N> 通过 ═══（run_tests.sh 容错注册块按此解析）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/verify-deploy.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

TMPD="$ROOT/.test-tmp/verify"
rm -rf "$TMPD"; mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT
TMP="$(cygpath -m "$TMPD" 2>/dev/null || echo "$TMPD")"

BOARD="kit-p9-test"
PROJ="$TMP/proj"
FAKE_HH="$TMP/hermes-home"

# ── 伪造器：把 $PROJECT/$HH 铺成 V2..V10 全绿的样子 ──
setup_full() {
  local p="$1" hh="$2"
  mkdir -p "$p/.hermes/config" "$p/.hermes/scripts" "$p/.hermes/Hermes模板库" \
           "$p/.hermes/通用角色库/deprecated" "$p/logs" "$hh/scripts" "$hh/logs" "$hh/skills/devops/kanban-executor"
  # V5：五目录 + 制度层 + USAGE + 角色库 11/deprecated 5
  mkdir -p "$p/.hermes/skills"
  cp "$ROOT/Hermes_制度层.md" "$p/.hermes/Hermes制度层.md"
  cp "$ROOT/USAGE.md" "$p/.hermes/USAGE.md"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11; do printf -- '---\nname: r%s\n---\n' "$i" > "$p/.hermes/通用角色库/r$i.md"; done
  cp "$p/.hermes/通用角色库/r1.md" "$p/.hermes/通用角色库/deprecated/d1.md"
  cp "$p/.hermes/通用角色库/r2.md" "$p/.hermes/通用角色库/deprecated/d2.md"
  cp "$p/.hermes/通用角色库/r3.md" "$p/.hermes/通用角色库/deprecated/d3.md"
  cp "$p/.hermes/通用角色库/r4.md" "$p/.hermes/通用角色库/deprecated/d4.md"
  cp "$p/.hermes/通用角色库/r5.md" "$p/.hermes/通用角色库/deprecated/d5.md"
  # V6：wf.env
  printf 'WF_BOARD=%s\n' "$BOARD" > "$p/.hermes/config/wf.env"
  # V3：11 个假 cc-*.md（经 CC_AGENTS_DIR 钩子隔离）
  mkdir -p "$TMP/agents"
  for i in 1 2 3 4 5 6 7 8 9 10 11; do printf -- '---\nname: cc-r%s\n---\n' "$i" > "$TMP/agents/cc-r$i.md"; done
  # V4：watchdog md5 一致 + kanban-executor version 一致（拷仓库原件）
  cp "$ROOT/scripts/kanban-watchdog.py" "$hh/scripts/kanban-watchdog.py"
  cp "$ROOT/skills/kanban-executor/SKILL.md" "$hh/skills/devops/kanban-executor/SKILL.md"
  # V9/V10：假包装壳（rc=0 + tick.log 写 rc=0 + touch 全局心跳）
  cat > "$hh/scripts/sentinel-$BOARD.sh" <<EOF
#!/usr/bin/env bash
echo "\$(date +%s) rc=0 dispatched=0 skipped=0 total_ready=1" >> "$p/logs/tick.log"
touch "$hh/logs/sentinel_state.json"
exit 0
EOF
  : > "$p/logs/tick.log"
}

# ── FAKE hermes：boards/cron list 返回含目标板名的输出（V7/V8 绿）──
mkdir -p "$TMPD/fakebin"
cat > "$TMPD/fakebin/hermes" <<FAKE
#!/usr/bin/env bash
case "\$1 \$2" in
  "kanban boards") echo "boards: $BOARD other" ;;
  "cron list")     echo "jobs: sentinel-$BOARD (every 5m)" ;;
esac
exit 0
FAKE
# MSYS PATH：用 \$ 转义的 HEREDOC 展开不了 $BOARD → 直接用未引号 heredoc 再写一份
cat > "$TMPD/fakebin/hermes" <<FAKE
#!/usr/bin/env bash
case "\$1 \$2" in
  "kanban boards") echo "boards: ${BOARD} other" ;;
  "cron list")     echo "jobs: sentinel-${BOARD} (every 5m)" ;;
esac
exit 0
FAKE
chmod +x "$TMPD/fakebin/hermes"

# V2 要跑 bootstrap-machine.sh 探测模式：它会白跑一整套探测。给它也塞一套假环境：
# HERMES_HOME 指到 FAKE_HH + CC_AGENTS_DIR 隔离 + HERMES_BIN 假 hermes。
# 注意 V2 需要 python 可用；探测里 bash 总能找到；claude 缺失只 WARN 不 FAIL。
COMMON_ENV=(env "HERMES_HOME=$FAKE_HH" "CC_AGENTS_DIR=$TMPD/agents" "HERMES_BIN=$TMPD/fakebin/hermes" "PATH=$TMPD/fakebin:$PATH")

echo "══ T1 伪造齐全 → rc=0 且「0 失败」══"
rm -rf "$PROJ" "$FAKE_HH"
setup_full "$PROJ" "$FAKE_HH"
T1_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$PROJ" --board "$BOARD" --skip-repo-tests 2>&1)
T1_RC=$?
if [[ "$T1_RC" -eq 0 ]] && grep -q '0 失败' <<<"$T1_OUT"; then
  ok "伪造齐全 rc=0 且输出含「0 失败」"
else
  echo "$T1_OUT"
  bad "伪造齐全未通过（rc=$T1_RC）"
fi

echo "══ T2 缺 wf.env → V6 FAIL 且 rc=1 ══"
rm -rf "$PROJ" "$FAKE_HH"
setup_full "$PROJ" "$FAKE_HH"
rm -f "$PROJ/.hermes/config/wf.env"
T2_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$PROJ" --board "$BOARD" --skip-repo-tests 2>&1)
T2_RC=$?
if [[ "$T2_RC" -eq 1 ]] && grep -q '^✗ V6' <<<"$T2_OUT"; then
  ok "缺 wf.env：V6 FAIL 且退出码 1"
else
  echo "$T2_OUT" | tail -5
  bad "缺 wf.env 未触发 V6 FAIL（rc=$T2_RC）"
fi

echo "══ T3 FAIL 行必带「修法：」══"
rm -rf "$PROJ" "$FAKE_HH"
mkdir -p "$PROJ" "$FAKE_HH"          # 空项目：V2..V10 大面积 FAIL
T3_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$PROJ" --board "$BOARD" --skip-repo-tests 2>&1)
T3_RC=$?
FAIL_LINES=$(grep -E '^✗' <<<"$T3_OUT")
N_F=$(grep -cE '^✗' <<<"$T3_OUT" || true)
NO_FIX=$(grep -E '^✗' <<<"$T3_OUT" | grep -v -- '修法：' || true)
if [[ "$T3_RC" -eq 1 && "$N_F" -ge 1 && -z "$NO_FIX" ]]; then
  ok "全部 $N_F 条 FAIL 行都带「修法：」"
else
  echo "$NO_FIX"
  bad "有 FAIL 行缺修法（rc=$T3_RC）"
fi

echo "══ T4 --skip-repo-tests 输出现 SKIP 且 rc 不受影响 ══"
rm -rf "$PROJ" "$FAKE_HH"
setup_full "$PROJ" "$FAKE_HH"
T4_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$PROJ" --board "$BOARD" --skip-repo-tests 2>&1)
T4_RC=$?
if grep -q '^○ V1.*SKIP' <<<"$T4_OUT" && [[ "$T4_RC" -eq 0 ]]; then
  ok "--skip-repo-tests：V1 标 SKIP 且 rc=0"
else
  echo "$T4_OUT" | tail -5
  bad "SKIP 语义不对（rc=$T4_RC）"
fi

echo "══ T5 汇总行契约 ══"
if grep -qE '═══ 验收：[0-9]+ 通过 / [0-9]+ 失败 ══' <<<"$T1_OUT"; then
  ok "汇总行格式「═══ 验收：N 通过 / M 失败 ══」"
else
  bad "汇总行格式不对"
fi

echo ""
echo "═══ 结果：$PASS 通过 ═══"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
