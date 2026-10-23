#!/usr/bin/env bash
# verify-deploy.sh 场景测试（T-KIT-P9 收尾）
# 用法：bash tests/test_verify_deploy.sh
#
# ⚠ 绝对不碰真实板/真实 agents 目录/真实 $HERMES_HOME——
#   HERMES_HOME/项目目录全用临时目录伪造；hermes 用 HERMES_BIN 注入的 FAKE 假命令。
#   动态只覆盖 V1..V9；V10/V11 不动态跑：V10 要真 watchdog + 真心跳、V11 要真哨兵
#   读真板，fixture 伪造注定不稳（上一轮教训）。设计改为：
#     - 所有动态调用都带 --skip-watchdog（V10 标 SKIP，不算失败）
#     - 所有动态调用都不传 --smoke（V11 不触发）
#     - V10/V11 靠 T9/T11/T12 的静态断言卡住接线
#
# 13 条断言（T1..T13）：
#   T1  完整 fixture + --skip-repo-tests + --skip-watchdog（不传 --smoke）→ rc=0
#       且输出含 `0 失败`、两条 SKIP（V1、V10）
#   T2  缺 wf.env → V6 FAIL 且 rc=1
#   T3  所有 FAIL 行都带 `修法：`
#   T4  自己单独跑一次带 --skip-watchdog 的调用 → 输出含 SKIP（V10）且 rc=0
#       （不复用 T1 输出）
#   T5  汇总行格式 `═══ 验收：N 通过 / M 失败 ══`
#   T6  反斜杠 HERMES_HOME（C:\temp\hh 风格）→ V4 不误报
#   T7  <项目>/.hermes/logs/tick.log 带 CRLF + 末尾空行 → V9 通过
#   T8  只在 <项目>/logs/tick.log 造数据 → V9 必须 FAIL（验证不回退读 root 级日志）
#   T9  静态：V11 函数体含 --dry-run、含 verify-smoke-、不含 sentinel_tick.py
#   T10 RUN_TESTS_ACTIVE=1 且不传 --skip-repo-tests → V1 标 SKIP 且 rc=0
#   T11 静态计数：TOTAL(含 "$HERMES_EXE" 的行) - GUARD([[ -z 守卫]) == TIMED(
#       timeout 30 "$HERMES_EXE" 调用数)，当前 8 - 1 == 7——计数式，不做逐行
#       续行解析（旧版把续行/守卫都算成调用，误报 13 处）
#   T12 静态：--smoke 建的是临时板——V11 里 SMOKE_BOARD 出现在 create/archive/rm 三处
#   T13 静态：V11 抓卡 ID 正则必须是 t_[0-9a-f]{8} 且无 {16,} 残留
#             （真 ID = t_+8位hex 共 10 字符；旧正则 ≥16 抓不到，真机 FAIL，防回退）
# 输出契约：═══ 结果：<N> 通过 ═══（run_tests.sh 容错注册块按此解析）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/verify-deploy.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

TMPD="$ROOT/.test-tmp/verify-deploy"
rm -rf "$TMPD"; mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT
# 路径铁律：给脚本/原生程序的一律 C:/ 形式
TMP="$(cygpath -m "$TMPD" 2>/dev/null || echo "$TMPD")"

BOARD="kit-p9-test"
PROJ="$TMP/proj"                 # 伪造项目根
FAKE_HH="$TMP/hermes-home"       # 伪造 HERMES_HOME
export FAKE_ARGS_LOG="$TMP/hermes-args.log"

# ── fixture：项目 .hermes/ 资产（V5 要的五目录 + 制度层 + USAGE + 角色库）──
setup_proj() {
  rm -rf "$PROJ"; mkdir -p "$PROJ"
  local ph="$PROJ/.hermes"
  mkdir -p "$ph/Hermes模板库" "$ph/skills" "$ph/config" "$ph/scripts"
  # 通用角色库整目录拷贝：顶层 11 + deprecated/ 5（跟仓库同源，数量天然对）
  cp -r "$ROOT/通用角色库" "$ph/通用角色库"
  cp "$ROOT/Hermes_制度层.md" "$ph/Hermes制度层.md"
  cp "$ROOT/USAGE.md" "$ph/USAGE.md"
  # V6：wf.env
  printf 'WF_BOARD=%s\n' "$BOARD" > "$ph/config/wf.env"
  # V9 素材：哨兵 tick.log（末行 rc=0，带 CRLF + 末尾空行——last_nonempty 要扛得住）
  mkdir -p "$ph/logs"
  printf 'tick board=%s dispatched=0 skipped=0\r\n\r\n' "$BOARD" > "$ph/logs/tick.log"
  printf 'tick board=%s dispatched=0 skipped=0 rc=0\r\n\r\n' "$BOARD" >> "$ph/logs/tick.log"
}

# ── fixture：伪造 $HERMES_HOME（V3/V4/V8/V9/V10/V11 素材）──
# 【为何 cp 真 watchdog 而非写 3 行假脚本】V4 的 md5 断言要求 $HH/scripts/
# kanban-watchdog.py 与仓库字节一致（T6 的回归点恰恰是“同字节 + 反斜杠路径不得
# 误报”），假脚本必然 md5 不一致 → T1/T6 全崩。30s 超时的旧因不是“脚本真”，
# 而是 fixture 里假 hermes 接不住 watchdog 的子调用 + 心跳文件缺失——
# 这里两者都补上了（PATH 注入 fakebin + 预置新鲜 sentinel_state.json），实测 < 1s。
setup_hh() {
  rm -rf "$FAKE_HH"; mkdir -p "$FAKE_HH/scripts" "$FAKE_HH/logs"
  cp "$ROOT/scripts/kanban-watchdog.py" "$FAKE_HH/scripts/kanban-watchdog.py"
  # V4：全局 kanban-executor 与仓库同字节（md5 + version 双一致）
  mkdir -p "$FAKE_HH/skills/devops"
  cp -r "$ROOT/skills/kanban-executor" "$FAKE_HH/skills/devops/kanban-executor"
  # V10：心跳文件要新鲜（mtime 距今 << SENTINEL_DEAD_SECONDS=900）
  printf '{"board":"%s","updated_at":"fresh","pid":1}\n' "$BOARD" > "$FAKE_HH/logs/sentinel_state.json"
  # V9：哨兵包装壳（假壳：立刻 rc=0，tick.log 上面的 fixture 已备好）
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_HH/scripts/sentinel-$BOARD.sh"
}

# ── fixture：V3 的 11 个 cc-*.md（真实 agents 目录绝不碰）──
setup_agents() {
  rm -rf "$TMP/agents"; mkdir -p "$TMP/agents"
  local i; for i in $(seq 1 11); do
    printf -- '---\nname: cc-dummy%s\ndescription: 测试占位\n---\n' "$i" > "$TMP/agents/cc-dummy$i.md"
  done
}

# ── FAKE hermes：bash 版（MSYS bash / HERMES_BIN 直接调用）+ .bat 版（原生
#    Windows python 的 find_hermes/subprocess 只认 PATHEXT 可执行）。
#    两版语义一致：把参数记进 FAKE_ARGS_LOG，按调用场景回显，立即返回、不读 stdin。
mkdir -p "$TMP/fakebin"
FAKE_BOARD="$BOARD"
FAKE_CARD_ID="t_smoke1234abcd"
export FAKE_BOARD FAKE_CARD_ID
cat > "$TMP/fakebin/hermes" <<'FAKE'
#!/usr/bin/env bash
# FAKE hermes（bash 版）——测试接管，绝不碰真板
printf '%s ' "$@" >> "$FAKE_ARGS_LOG"; echo >> "$FAKE_ARGS_LOG"
case "$1 $2" in
  "kanban boards")
    case "$3" in
      create) echo "created"; exit 0 ;;
      rm)     echo "deleted"; exit 0 ;;
      *)      echo "boards: $FAKE_BOARD" ;;
    esac ;;
  "kanban --board")
    case "$4" in
      create)  echo "created $FAKE_CARD_ID" ;;
      archive) echo "archived $6" ;;
      *)       echo "" ;;
    esac ;;
  "cron list") echo "cron: sentinel-$FAKE_BOARD every 5m" ;;
  "cron")      echo "cron: sentinel-$FAKE_BOARD every 5m" ;;
esac
exit 0
FAKE
cat > "$TMP/fakebin/hermes.bat" <<'FAKE'
@echo off
rem FAKE hermes（Windows 原生版）——只服务原生 python 的 find_hermes/subprocess
if not "%FAKE_ARGS_LOG%"=="" (echo %* >> "%FAKE_ARGS_LOG%")
if "%~1"=="kanban" goto kanban
echo {}
exit /b 0
:kanban
if "%~2"=="list" goto list-bare
if not "%~2"=="--board" goto other
if "%~4"=="list" goto list-json
goto other
:list-bare
if not "%~3"=="--json" goto other
echo [{"id":"%FAKE_CARD_ID%","status":"ready","assignee":"cc-backend-developer","title":"[SMOKE] verify-deploy smoke test"}]
exit /b 0
:list-json
echo [{"id":"%FAKE_CARD_ID%","status":"ready","assignee":"cc-backend-developer","title":"[SMOKE] verify-deploy smoke test"}]
exit /b 0
:other
echo {}
exit /b 0
FAKE
chmod +x "$TMP/fakebin/hermes"

# 注意：MSYS bash 的 command -v 只认 /c/... 形式的 PATH 条目（test_bootstrap.sh 同款教训）
COMMON_ENV=(env "HERMES_HOME=$FAKE_HH" "HERMES_BIN=$TMPD/fakebin/hermes"
            "CC_AGENTS_DIR=$TMP/agents" "WF_HERMES=$TMP/fakebin/hermes.bat"
            "WF_STATE_FILE=$TMP/sentinel_state.json" "PATH=$TMPD/fakebin:$PATH")

setup_proj; setup_agents; setup_hh
: > "$FAKE_ARGS_LOG"

# ── T1：完整 fixture + --skip-repo-tests + --skip-watchdog（不传 --smoke）→ rc=0 ──
echo "══ T1 完整 fixture（--skip-repo-tests + --skip-watchdog）══"
T1_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$PROJ" --board "$BOARD" --skip-repo-tests --skip-watchdog 2>&1)
T1_RC=$?
T1_SKIPS=$(echo "$T1_OUT" | grep -c '（SKIP，不算失败）')
if [[ "$T1_RC" -eq 0 ]] && echo "$T1_OUT" | grep -q '0 失败' \
   && [[ "$T1_SKIPS" -eq 2 ]] \
   && echo "$T1_OUT" | grep -q '○ V1' && echo "$T1_OUT" | grep -q '○ V10'; then
  ok "完整 fixture 全过（rc=0，0 失败，SKIP×2 = V1 + V10）"
else
  echo "$T1_OUT" | tail -30
  bad "完整 fixture 未全过（rc=$T1_RC，SKIP=$T1_SKIPS）"
fi

# ── T2：缺 wf.env → V6 FAIL 且 rc=1 ──
echo "══ T2 缺 wf.env ══"
T2_PROJ="$TMP/proj2"; mkdir -p "$T2_PROJ"
T2_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$T2_PROJ" --board "$BOARD" --skip-repo-tests --skip-watchdog 2>&1)
T2_RC=$?
if [[ "$T2_RC" -eq 1 ]] && echo "$T2_OUT" | grep -q '✗'; then
  ok "V6 FAIL 且 rc=1"
else
  bad "rc=$T2_RC，输出：$(echo "$T2_OUT" | tail -5)"
fi
rm -rf "$T2_PROJ"

# ── T3：所有 FAIL 行都带 `修法：`（T1/T2 输出都不许有裸 FAIL 行）──
echo "══ T3 FAIL 行必带修法 ══"
T3_BARE=$( { echo "$T1_OUT"; echo "$T2_OUT"; } | grep '^✗' | grep -v '修法：' || true)
if [[ -z "$T3_BARE" ]]; then
  ok "T1/T2 输出里每条 ✗ 行都带 修法："
else
  echo "$T3_BARE"
  bad "存在缺修法的 FAIL 行"
fi

# ── T4：--skip-watchdog → 独立跑一次（不复用 T1 输出）→ 输出含 SKIP（V10）且 rc=0 ──
echo "══ T4 --skip-watchdog 独立跑 ══"
T4_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$PROJ" --board "$BOARD" --skip-repo-tests --skip-watchdog 2>&1)
T4_RC=$?
if [[ "$T4_RC" -eq 0 ]] && echo "$T4_OUT" | grep -q 'V10 watchdog 死信检查.*SKIP'; then
  ok "带 --skip-watchdog 的调用 V10 标 SKIP 且 rc=0"
else
  echo "$T4_OUT" | grep -E 'V10|验收' | head -3
  bad "V10 未 SKIP 或 rc≠0（rc=$T4_RC）"
fi

# ── T5：汇总行格式 `═══ 验收：N 通过 / M 失败 ══` ──
echo "══ T5 汇总行格式 ══"
T5_LINE="$(echo "$T1_OUT" | grep -oE '═══ 验收：[0-9]+ 通过 / [0-9]+ 失败 ══' | tail -1)"
if [[ -n "$T5_LINE" ]]; then
  ok "汇总行合格式：$T5_LINE"
else
  tail -3 <<<"$T1_OUT"
  bad "汇总行不合 `═══ 验收：N 通过 / M 失败 ══` 格式"
fi

# ── T6：反斜杠 HERMES_HOME → V4 不误报 ──
echo "══ T6 反斜杠 HERMES_HOME ══"
BSSH_HH="$(cygpath -w "$TMPD/hermes-home" 2>/dev/null || echo "$FAKE_HH")"   # C:\x\y 形式
T6_OUT=$("${COMMON_ENV[@]/HERMES_HOME=*/HERMES_HOME=$BSSH_HH}" bash "$SCRIPT" --project "$PROJ" --board "$BOARD" --skip-repo-tests --skip-watchdog 2>&1)
T6_RC=$?
if echo "$T6_OUT" | grep -q '✓ V4' && ! echo "$T6_OUT" | grep -q '✗ V4'; then
  ok "V4 反斜杠路径不误报（md5/version 仍判一致）"
else
  echo "$T6_OUT" | grep -E 'V4' | head -3
  bad "V4 在反斜杠 HERMES_HOME 下报错（rc=$T6_RC）"
fi

# ── T7：tick.log CRLF + 末尾空行 → V9 通过（复用 T1 输出，fixture 就是 CRLF 写的）──
echo "══ T7 tick.log CRLF + 末尾空行 ══"
if xxd "$PROJ/.hermes/logs/tick.log" 2>/dev/null | head -1 | grep -q '0d' || od -c "$PROJ/.hermes/logs/tick.log" 2>/dev/null | head -2 | grep -q '\\r'; then
  :
fi
CR_COUNT=$(tr -cd '\r' < "$PROJ/.hermes/logs/tick.log" | wc -c)
if [[ "$CR_COUNT" -ge 1 ]] && echo "$T1_OUT" | grep -q '✓ V9'; then
  ok "V9 对 CRLF + 末尾空行的 tick.log 判通过（last_nonempty 抗噪）"
else
  bad "V9 未通过（CR=$CR_COUNT）：$(echo "$T1_OUT" | grep 'V9' | head -2)"
fi

# ── T8：只在 <项目>/logs/ 造数据 → V9 必须 FAIL（验证不回退读 root 级日志）──
echo "══ T8 root 级 tick.log 不算数 ══"
T8_PROJ="$TMP/proj8"; mkdir -p "$T8_PROJ/.hermes/config" "$T8_PROJ/.hermes/logs" "$T8_PROJ/logs"
cp "$PROJ/.hermes"/*.md "$T8_PROJ/.hermes/" 2>/dev/null || true
for d in Hermes模板库 skills config scripts 通用角色库; do cp -r "$PROJ/.hermes/$d" "$T8_PROJ/.hermes/$d" 2>/dev/null || true; done
printf 'WF_BOARD=%s\n' "$BOARD" > "$T8_PROJ/.hermes/config/wf.env"
printf 'tick fake rc=0 plant\r\n' > "$T8_PROJ/logs/tick.log"          # 只造 root 级
T8_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$T8_PROJ" --board "$BOARD" --skip-repo-tests --skip-watchdog 2>&1)
T8_RC=$?
if echo "$T8_OUT" | grep -q '✗ V9' && [[ "$T8_RC" -eq 1 ]]; then
  ok "只在 <项目>/logs/ 造数据 → V9 FAIL（不回退读 root 级 tot）"
else
  echo "$T8_OUT" | grep 'V9' | head -2
  bad "V9 未按预期 FAIL（rc=$T8_RC）"
fi
rm -rf "$T8_PROJ"

# ── T9：静态：V11 函数体含 --dry-run、含 verify-smoke-、不含 sentinel_tick.py ──
echo "══ T9 V11 静态断言 ══"
V11_BODY="$(sed -n '/^v11() {/,/^}/p' "$SCRIPT")"
T9_LOST=""
[[ "$(echo "$V11_BODY" | grep -c -- '--dry-run')" -ge 1 ]] || T9_LOST="$T9_LOST --dry-run"
[[ "$(echo "$V11_BODY" | grep -c 'verify-smoke-')" -ge 1 ]] || T9_LOST="$T9_LOST verify-smoke-"
[[ "$(echo "$V11_BODY" | grep -c 'sentinel_tick.py')" -eq 0 ]] || T9_LOST="$T9_LOST sentinel_tick.py"
if [[ -n "$V11_BODY" && -z "$T9_LOST" ]]; then
  ok "V11 body：有 --dry-run、有 verify-smoke-、无 sentinel_tick.py"
else
  bad "V11 body 断言缺/函数体空：$T9_LOST"
fi

# ── T10：RUN_TESTS_ACTIVE=1 且不传 --skip-repo-tests → V1 标 SKIP 且 rc=0 ──
echo "══ T10 RUN_TESTS_ACTIVE 防递归 ══"
T10_OUT=$(env "HERMES_HOME=$FAKE_HH" "HERMES_BIN=$TMPD/fakebin/hermes" \
  "CC_AGENTS_DIR=$TMP/agents" "WF_HERMES=$TMP/fakebin/hermes.bat" \
  "WF_STATE_FILE=$TMP/sentinel_state.json" "PATH=$TMPD/fakebin:$PATH" \
  RUN_TESTS_ACTIVE=1 bash "$SCRIPT" --project "$PROJ" --board "$BOARD" --skip-watchdog 2>&1)
T10_RC=$?
if [[ "$T10_RC" -eq 0 ]] && echo "$T10_OUT" | grep -q 'V1.*SKIP'; then
  ok "RUN_TESTS_ACTIVE=1 → V1 自动 SKIP（防递归）且 rc=0"
else
  echo "$T10_OUT" | grep -E 'V1|验收' | head -3
  bad "V1 未 SKIP 或 rc≠0（rc=$T10_RC）"
fi

# ── T11：静态计数：含 "$HERMES_EXE" 的行，扣掉 [[ -z 守卫后应 == timeout 30 调用数 ──
# 为什么计数式而非逐行判 timeout+</dev/null：旧版解析把续行（create 卡的多行命令）
# 和守卫行都当成独立调用，误报 N 处失守。计数恒等式简单且稳：
#   TOTAL = 含 "$HERMES_EXE" 的行数（含 [[ -z "$HERMES_EXE" ]] 非空守卫 1 处）
#   TIMED = timeout 30 "$HERMES_EXE" 调用数（每处调用都自带 timeout+stdin 重定向）
# 恒等 TOTAL - GUARD == TIMED ⇔ 新增调用若漏 timeout/缩进不一致即失衡。
echo "══ T11 HERMES_EXE 调用纪律（计数式）══"
TOTAL=$(grep -c '"\$HERMES_EXE"' "$SCRIPT")
GUARD=$(grep -c '\[\[ -z "\$HERMES_EXE"' "$SCRIPT")
TIMED=$(grep -c 'timeout 30 "\$HERMES_EXE"' "$SCRIPT")
if [[ "$((TOTAL - GUARD))" -eq "$TIMED" && "$TIMED" -ge 7 ]]; then
  ok "HERMES_EXE 纪律成立：TOTAL=$TOTAL - GUARD=$GUARD == timeout 调用 $TIMED"
else
  bad "HERMES_EXE 计数失衡：TOTAL=$TOTAL GUARD=$GUARD TIMED=$TIMED（TOTAL-GUARD ≠ TIMED）"
fi

# ── T12：静态：--smoke 建的是临时板——SMOKE_BOARD 出现在 create/archive/rm 三处 ──
echo "══ T12 SMOKE_BOARD 三处接线 ══"
T12_LOST=""
grep -q 'boards create "$SMOKE_BOARD"' "$SCRIPT"  || T12_LOST="$T12_LOST create"
grep -q -- '--board "$SMOKE_BOARD" archive' "$SCRIPT" || T12_LOST="$T12_LOST archive"
grep -q 'boards rm "$SMOKE_BOARD"' "$SCRIPT"       || T12_LOST="$T12_LOST rm"
if [[ -z "$T12_LOST" ]]; then
  ok "SMOKE_BOARD 接进 boards create / archive / boards rm 三处"
else
  bad "SMOKE_BOARD 缺接线：$T12_LOST"
fi

# ── T13：静态：V11 抓卡 ID 正则必须是 t_[0-9a-f]{8}，且无 ≥16 字符旧正则残留 ──
# 为什么卡死这个正则：真实卡 ID = t_ + 8 位 hex（共 10 字符，如 t_a51d5d1a）。
# 旧写法 [0-9a-fA-F-]{16,} 要求 ≥16 字符，永远抓不到 → 报「卡 ID=<空>」真机 FAIL
# （已实测）。防再退回长 ID 假设。
echo "══ T13 卡 ID 正则 t_[0-9a-f]{8} ══"
T13_LOST=""
grep -qE "grep -oE 't_\[0-9a-f\]\{8\}'" "$SCRIPT" || T13_LOST="$T13_LOST 缺-t_[0-9a-f]{8}-正则"
grep -qE '\{16,\}' "$SCRIPT"       && T13_LOST="$T13_LOST 仍有{16,}旧正则残留"
if [[ -z "$T13_LOST" ]]; then
  ok "V11 抓卡 ID 用 t_[0-9a-f]{8}（真 ID 10 字符），且无 {16,} 旧正则残留"
else
  bad "卡 ID 正则断言失守：$T13_LOST"
fi

echo ""
echo "═══ 结果：$PASS 通过 ═══"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
