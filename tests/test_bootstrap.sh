#!/usr/bin/env bash
# bootstrap-machine.sh 场景测试（T-KIT-P7）
# 用法：bash tests/test_bootstrap.sh
#
# ⚠ 绝对不许碰真实的 ~/.claude/agents、真实 $HERMES_HOME、真实 cron——
#   HERMES_HOME/项目目录全用临时目录伪造；hermes 用 PATH 注入的 FAKE 假命令。
# 6 条断言：
#   T1 默认（无 --apply）跑完：项目目录零写入（find|sort 前后一致）+ 输出含 OK/WARN/FAIL 计数行
#   T2 --apply：wf.env 生成，WF_BOARD=传入板名，三条路径均为 C:/ 形式（不含 /c/）
#   T3 --apply 二次运行：wf.env 内容不变（幂等），且存在 .wf.env.bak.* 备份
#   T4 --apply 时 wf.env 已有 WF_MAX_CONCURRENT=9：二次运行后仍是 9（不覆盖用户值）
#   T5 --board 与已有 wf.env 的 WF_BOARD 不一致：输出含 MISMATCH/板名不匹配 且返回非 0
#   T6 --with-cron 被 FAKE hermes 接住：断言参数含 every 5m / --no-agent / --script sentinel-<board>.sh
# 输出契约：═══ 结果：<N> 通过 ═══（run_tests.sh 容错注册块按此解析）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/bootstrap-machine.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

TMPD="$ROOT/.test-tmp/bootstrap"
rm -rf "$TMPD"; mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT
# 路径铁律：给脚本/原生程序的一律 C:/ 形式
TMP="$(cygpath -m "$TMPD" 2>/dev/null || echo "$TMPD")"

BOARD="kit-p7-test"
PROJ="$TMP/proj"                 # 伪造项目根
FAKE_HH="$TMP/hermes-home"       # 伪造 HERMES_HOME
mkdir -p "$FAKE_HH/scripts" "$FAKE_HH/logs" "$PROJ/.hermes/config" "$PROJ/.hermes/skills" \
         "$PROJ/.hermes/scripts" "$PROJ/.hermes/Hermes模板库" "$PROJ/.hermes/通用角色库"
cp "$ROOT/Hermes_制度层.md" "$PROJ/.hermes/Hermes制度层.md"

# FAKE hermes：把收到的参数写文件供断言（每次调用一行，参数空格拼接——
# 断言按子串 grep，"--script sentinel-*.sh" 必须同在一行才验得出 CLI 契约）；
# boards/cron list 返回空（逼出 create 分支）
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/hermes" <<'FAKE'
#!/usr/bin/env bash
printf '%s ' "$@" >> "$FAKE_ARGS_LOG"
echo >> "$FAKE_ARGS_LOG"
case "$1 $2" in
  "kanban boards") echo "boards: other-board" ;;
  "cron list")     echo "(no cron)" ;;
esac
exit 0
FAKE
chmod +x "$TMP/fakebin/hermes"
export FAKE_ARGS_LOG="$TMP/hermes-args.log"

# 隔离探测：CC_AGENTS_DIR 指到临时目录（bootstrap 的测试钩子，绝不碰真实 ~/.claude/agents）
export CC_AGENTS_DIR="$TMP/agents"
# PATH 注意：MSYS bash 的 command -v 只认 /c/... 形式的 PATH 条目（C:/ 形式查不到），
# 假 hermes 必须用 $TMPD（/c/... 本形式）拼进 PATH，否则真 venv hermes 抢跑、沙箱失守。
# HERMES_BIN：bootstrap 的测试钩子——PATH 注入接不住 $HERMES_EXE 绝对路径调用，必须显式接管
COMMON_ENV=(env "HERMES_HOME=$FAKE_HH" "CC_AGENTS_DIR=$CC_AGENTS_DIR" "HERMES_BIN=$TMP/fakebin/hermes" "PATH=$TMPD/fakebin:$PATH")

snapshot() { (cd "$PROJ" && find . | sort); }

echo "══ T1 默认（无 --apply）零写入 ══"
BEFORE=$(snapshot)
T1_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$PROJ" --board "$BOARD" 2>&1)
T1_RC=$?
AFTER=$(snapshot)
if [[ "$BEFORE" == "$AFTER" ]]; then
  ok "项目目录零写入（find|sort 前后一致）"
else
  diff <(echo "$BEFORE") <(echo "$AFTER") | head -5
  bad "探测模式写了项目目录"
fi
if echo "$T1_OUT" | grep -qE '检查结果：OK=[0-9]+ WARN=[0-9]+ FAIL=[0-9]+'; then
  ok "输出含 OK/WARN/FAIL 计数行"
else
  bad "输出缺计数行（rc=$T1_RC）：$(echo "$T1_OUT" | tail -3)"
fi

echo "══ T2 --apply 生成 wf.env ══"
T2_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$PROJ" --board "$BOARD" --apply 2>&1)
T2_RC=$?
WFE="$PROJ/.hermes/config/wf.env"
if [[ -f "$WFE" ]] && grep -q "^WF_BOARD=$BOARD$" "$WFE"; then
  ok "wf.env 已生成且 WF_BOARD=$BOARD"
else
  echo "$T2_OUT" | tail -5
  bad "wf.env 未生成或 WF_BOARD 不对（rc=$T2_RC）"
fi
# 三条路径（WF_REPO/WF_PYTHON/WF_BASH）必须是 C:/ 或 *_HOME 形式，禁止 /c/
BAD_PATHS=$(grep -E '^(WF_REPO|WF_PYTHON|WF_BASH)=' "$WFE" | grep -E '=(/c/)|=(/[a-z]/)' || true)
if [[ -z "$BAD_PATHS" ]]; then
  ok "三条路径均为 C:/ 形式（无 /c/ 泄漏）"
else
  bad "路径含 MSYS 形式：$BAD_PATHS"
fi

echo "══ T3 幂等 + 备份 ══"
C1="$(cat "$WFE")"
md5sum "$WFE" > /dev/null  # 触发读
T3_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$PROJ" --board "$BOARD" --apply 2>&1)
C2="$(cat "$WFE")"
if [[ "$C1" == "$C2" ]]; then
  ok "二次 --apply wf.env 内容不变（幂等）"
else
  diff <(echo "$C1") <(echo "$C2") | head -10
  bad "二次 --apply 改了 wf.env 内容"
fi
BAK_N=$(find "$PROJ/.hermes/config" -name '.wf.env.bak.*' -type f | wc -l)
if [[ "$BAK_N" -ge 1 ]]; then
  ok "存在 .wf.env.bak.* 备份（$BAK_N 份）"
else
  bad "没有 .wf.env.bak.* 备份文件"
fi

echo "══ T4 用户已改值不被覆盖 ══"
printf 'WF_MAX_CONCURRENT=9\n' >> "$WFE"
T4_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$PROJ" --board "$BOARD" --apply 2>&1)
V9=$(grep -E '^WF_MAX_CONCURRENT=' "$WFE" | tail -1 | cut -d= -f2)
if [[ "$V9" == "9" ]]; then
  ok "WF_MAX_CONCURRENT=9 保持不变（不覆盖用户值）"
else
  bad "用户值被覆盖：WF_MAX_CONCURRENT=$V9"
fi

echo "══ T5 板名不一致报错 ══"
T5_PROJ="$TMP/proj-mismatch"; mkdir -p "$T5_PROJ/.hermes/config"
printf 'WF_BOARD=other-board\n' > "$T5_PROJ/.hermes/config/wf.env"
T5_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$T5_PROJ" --board "$BOARD" --apply 2>&1)
T5_RC=$?
if [[ "$T5_RC" -ne 0 ]] && echo "$T5_OUT" | grep -qE 'MISMATCH|板名不匹配'; then
  ok "MISMATCH 提示 + 非零退出"
else
  bad "rc=$T5_RC，输出：$(echo "$T5_OUT" | tail -3)"
fi

echo "══ T6 --with-cron 被 FAKE hermes 接住 ══"
: > "$FAKE_ARGS_LOG"
T6_OUT=$("${COMMON_ENV[@]}" bash "$SCRIPT" --project "$PROJ" --board "$BOARD" --apply --with-cron 2>&1)
T6_RC=$?
ARGS=$(cat "$FAKE_ARGS_LOG" 2>/dev/null || true)
if [[ "$T6_RC" -eq 0 ]] && echo "$ARGS" | grep -q "every 5m" \
   && echo "$ARGS" | grep -q -- "--no-agent" \
   && echo "$ARGS" | grep -q -- "--script sentinel-$BOARD.sh"; then
  ok "FAKE hermes 收到 create 参数（every 5m / --no-agent / --script sentinel-$BOARD.sh）"
else
  echo "$T6_OUT" | tail -5
  echo "--- FAKE hermes 收到的参数 ---"; echo "$ARGS" | head -20
  bad "cron create 参数不对或未被假 hermes 接住（rc=$T6_RC）"
fi
# 包装壳生成且落在 $HERMES_HOME/scripts/（--script 只认文件名的约束）
if [[ -f "$FAKE_HH/scripts/sentinel-$BOARD.sh" ]]; then
  ok "包装壳已生成：\$HERMES_HOME/scripts/sentinel-$BOARD.sh"
else
  bad "包装壳未生成在 \$HERMES_HOME/scripts/ 下"
fi

echo ""
echo "═══ 结果：$PASS 通过 ═══"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
