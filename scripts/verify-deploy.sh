#!/usr/bin/env bash
# verify-deploy.sh — 部署后能力验收（T-KIT-P9）
#
# 用法：
#   bash scripts/verify-deploy.sh --project <项目根> [--board <slug>] [--skip-repo-tests] [--smoke]
#
#   --project          项目根目录（必填）
#   --board            看板 slug；缺省时从项目 .hermes/config/wf.env 的 WF_BOARD 读
#   --skip-repo-tests  跳过 V1 仓库自检（标 SKIP，不算失败）
#   --smoke            追加 V11 冒烟：建 [SMOKE] 卡 → 哨兵 --dry-run 计划 → 归档清理（trap 保证）
#                      （plan-only：不写 state、不真派单、不烧 token）
#   -h | --help        帮助
#
# 外部调用铁律：每条 hermes/python 外部命令统一前置 timeout（hermes/python 30s、
# V2 整体 bootstrap 探测 120s）并 </dev/null 重定向 stdin——CLI 读到非 tty 的 stdin
# 会等输入永不返回（真机实测 V7 挂 45 分钟不返回）。rc=124（超时）按 FAIL 报，
# 修法注明「30s 未返回，多半是 CLI 在等 stdin 或网关锁」。
# 逐项检查 V1..V10（V11 仅 --smoke），每项要么「✓ Vn 说明」，要么
# 「✗ Vn 说明 —— 修法：<可粘贴命令>」；FAIL 行必带修法。
# 末尾汇总「═══ 验收：N 通过 / M 失败 ══」，有 FAIL 退 1，全过退 0。
#
# 测试钩子（照抄 bootstrap-machine.sh 的约定）：
#   HERMES_BIN       覆盖 hermes 可执行（测试注入假 hermes）
#   CC_AGENTS_DIR    覆盖 CC 角色目录（默认 ~/.claude/agents，测试隔离用）
#   HERMES_HOME      覆盖全局 home（缺省 Windows=$LOCALAPPDATA/hermes，其余 ~/.hermes）
#   RUN_TESTS_ACTIVE 由 tests/run_tests.sh export；verify 侧检测到非空即 V1 自动 SKIP（防递归）
#
# Windows 路径铁律：凡拼给原生程序（python.exe/hermes.exe）的路径一律 C:/x/y，
# 统一走 to_native()（cygpath -m 可用则用），禁止 /c/x/y。
set -uo pipefail
# 注意：不用 set -e —— 必须跑完全部检查再汇总

to_native() { if command -v cygpath &>/dev/null; then cygpath -m "$1" 2>/dev/null || echo "$1"; else echo "$1"; fi; }

# 取最后一条非空行（去 \r）：tick.log 类日志常带 CRLF 和尾部空行，tail -1 会取到空行
last_nonempty() {
  if [[ -n "${1:-}" ]]; then
    awk 'NF{last=$0} END{print last}' "$(to_native "$1")" 2>/dev/null | tr -d '\r'
  else
    awk 'NF{last=$0} END{print last}' 2>/dev/null | tr -d '\r'
  fi
}

# 哨兵日志唯一真源：哨兵 cron 的 workdir 是 <项目>/.hermes，tick.log 固定落 .hermes/logs/；
# 不回退读 root 级 <项目>/logs/（那里不是哨兵写的，读了会掩盖哨兵没跑的真相）
proj_log() {
  echo "$PROJECT/.hermes/logs/tick.log"
}

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ── 结果登记 ─────────────────────────────────────────────────────
N_PASS=0; N_FAIL=0; N_SKIP=0
ok()    { N_PASS=$((N_PASS + 1)); echo "✓ $*"; }
fail()  { N_FAIL=$((N_FAIL + 1)); echo "✗ $*"; }
skip()  { N_SKIP=$((N_SKIP + 1)); echo "○ $*（SKIP，不算失败）"; }

# ── 参数解析 ─────────────────────────────────────────────────────
PROJECT=""
BOARD_ARG=""
SKIP_REPO_TESTS=false
SMOKE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) [[ $# -ge 2 ]] || { echo "✗ --project 需要值（用法见 --help）" >&2; exit 2; }
               PROJECT="$2"; shift 2 ;;
    --board)   [[ $# -ge 2 ]] || { echo "✗ --board 需要值（用法见 --help）" >&2; exit 2; }
               BOARD_ARG="$2"; shift 2 ;;
    --skip-repo-tests) SKIP_REPO_TESTS=true; shift ;;
    --smoke)   SMOKE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "✗ 缺 --project <项目根>（--help 看用法）" >&2
  exit 2
fi
if [[ ! -d "$PROJECT" ]]; then
  echo "✗ 项目目录不存在：$PROJECT" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PH="$PROJECT/.hermes"          # 项目 .hermes/
WFE="$PH/config/wf.env"        # wf.env 常量：多处要用

# ── 环境（缺省值与 bootstrap-machine.sh 同款）─────────────────────
if [[ -n "${HERMES_HOME:-}" ]]; then
  HH="$HERMES_HOME"
elif [[ -n "${LOCALAPPDATA:-}" ]]; then
  HH="$LOCALAPPDATA/hermes"
else
  HH="$HOME/.hermes"
fi
AGENTS_DIR="${CC_AGENTS_DIR:-$HOME/.claude/agents}"

HERMES_EXE=""
_c="$(command -v hermes 2>/dev/null || true)"
[[ -n "$_c" ]] && HERMES_EXE="$(to_native "$_c")"
if [[ -z "$HERMES_EXE" ]]; then
  for _g in "$HH"/installs/*/environments/*/venv/Scripts/hermes.exe; do
    if [[ -f "$_g" ]]; then HERMES_EXE="$(to_native "$_g")"; break; fi
  done
fi
# HERMES_BIN 显式覆盖，优先于自动探测（测试接管钩子）
HERMES_EXE="${HERMES_BIN:-$HERMES_EXE}"
HERMES_EXE="${HERMES_EXE:-hermes}"

# 板名边界匹配：左右必须是非名字字符，防 hljjt 误命中 hljjt_x 等前缀重叠板名
_board_hit() { printf '%s\n' "$1" | grep -Eq "(^|[^a-zA-Z0-9_-])${2}([^a-zA-Z0-9_-]|$)"; }

# 无板名（--board 缺省且 wf.env 读不出）时，看板相关项只能 FAIL
BOARD=""   # 待 V6 前定出

# V11 冒烟卡清理（EXIT trap 兜底，无论成败都归档 SMOKE 卡）
SMOKE_CARD_ID=""
SMOKE_ARCHIVED=false
smoke_cleanup() {
  if [[ -n "$SMOKE_CARD_ID" && "$SMOKE_ARCHIVED" == "false" ]]; then
    timeout 30 "$HERMES_EXE" kanban --board "$BOARD" archive "$SMOKE_CARD_ID" </dev/null >/dev/null 2>&1 || true
  fi
}
# trap 常置：非冒烟时 SMOKE_CARD_ID 为空 → no-op
trap smoke_cleanup EXIT

# ════════════════════════════════════════════════════════════════
# 检查项
# ════════════════════════════════════════════════════════════════

# ── V1 仓库自检：tests/run_tests.sh 0 失败 ──
v1() {
  # 防递归：run_tests.sh → test_verify_deploy → verify-deploy V1 → run_tests.sh 死循环
  # （真机实测进程树 run_tests → run_tests → verify-deploy）。run_tests.sh 会
  # export RUN_TESTS_ACTIVE=1，此处检测到非空即自动 SKIP。
  if [[ -n "${RUN_TESTS_ACTIVE:-}" ]]; then
    skip "V1 仓库自检（检测到已在 run_tests.sh 内，自动 SKIP）"
    return 0
  fi
  if $SKIP_REPO_TESTS; then
    skip "V1 仓库自检（--skip-repo-tests 已指定）"
    return 0
  fi
  local out rc failn
  out="$(bash "$REPO_ROOT/tests/run_tests.sh" 2>&1)"
  rc=$?
  # 抓「═══ 结果：N 通过 / M 失败 ═══」里的失败数；=0 且 rc=0 才算过
  failn="$(sed -n 's/.*═══ 结果：[0-9]* 通过 \/ \([0-9]*\) 失败.*/\1/p' <<<"$out" | last_nonempty "")"
  if [[ $rc -eq 0 && "$failn" == "0" ]]; then
    ok "V1 仓库自检通过（0 失败）"
  else
    fail "V1 仓库自检未过（rc=$rc，失败=${failn:-?}）\
—— 修法：cd $(to_native "$REPO_ROOT") && bash tests/run_tests.sh  # 逐条按 ✗ 修"
  fi
}

# ── V2 接线自检：bootstrap 探测模式 FAIL=0 ──
v2() {
  if [[ -z "$BOARD" ]]; then
    fail "V2 接线自检无法跑（板名未知）\
—— 修法：补传 --board <板>，或修好项目 .hermes/config/wf.env 的 WF_BOARD"
    return 0
  fi
  local out rc
  # 整段探测 120s 兜底：bootstrap 内部会调 hermes/python 等多个外部命令
  out="$(timeout 120 bash "$REPO_ROOT/scripts/bootstrap-machine.sh" --project "$(to_native "$PROJECT")" --board "$BOARD" </dev/null 2>&1)"
  rc=$?
  if [[ $rc -eq 124 ]]; then
    fail "V2 接线自检 120s 未返回（多半被锁或输入等待卡死）\
—— 修法：bash scripts/bootstrap-machine.sh --project <项目> --board <板>  # 手动跑看卡在哪一步"
    return 0
  fi
  if grep -q 'FAIL=0' <<<"$out"; then
    ok "V2 接线自检 FAIL=0"
  else
    fail "V2 接线自检有硬条件 FAIL\
—— 修法：bash scripts/bootstrap-machine.sh --project <项目> --board <板>  # 看检查单各 FAIL 项修完重跑"
  fi
}

# ── V3 角色已装：cc-*.md 数量 == 11 ──
v3() {
  local n
  n="$(find "$AGENTS_DIR" -maxdepth 1 -name 'cc-*.md' -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$n" -eq 11 ]]; then
    ok "V3 CC 角色已装（$(to_native "$AGENTS_DIR") 下 cc-*.md = 11）"
  else
    fail "V3 CC 角色数量为 $n，应 11（$AGENTS_DIR）\
—— 修法：bash scripts/install-claude-agents.sh  # 幂等重装 11 个 cc-*.md"
  fi
}

# ── V4 全局件一致：watchdog md5 + kanban-executor SKILL version ──
v4() {
  local src_wd="$REPO_ROOT/scripts/kanban-watchdog.py"
  local dst_wd="$HH/scripts/kanban-watchdog.py"
  if [[ ! -f "$dst_wd" ]]; then
    fail "V4 缺全局 watchdog：$(to_native "$dst_wd")\
—— 修法：cp \"$(to_native "$src_wd")\" \"$(to_native "$dst_wd")\""
    return 0
  fi
  local m1 m2
  # md5sum 是原生程序：路径必须过 to_native，反斜杠 Windows 路径会读不到 → 得空串假报"不一致"
  m1="$(md5sum "$(to_native "$src_wd")" 2>/dev/null | cut -d' ' -f1 | tr -d '\r')"
  m2="$(md5sum "$(to_native "$dst_wd")" 2>/dev/null | cut -d' ' -f1 | tr -d '\r')"
  if [[ -z "$m1" || -z "$m2" ]]; then
    fail "V4 watchdog md5 读不到（仓库=${m1:-<空>} 全局=${m2:-<空>}），无法比对\
—— 修法：核对文件路径与权限（$(to_native "$src_wd") / $(to_native "$dst_wd")）； \
路径含反斜杠时用 cygpath -m 转正斜杠后再试"
    return 0
  fi
  local src_md="$REPO_ROOT/skills/kanban-executor/SKILL.md"
  local dst_md="$HH/skills/devops/kanban-executor/SKILL.md"
  local v1_v v2_v
  v1_v="$(grep -m1 -E '^version:' "$(to_native "$src_md")" 2>/dev/null | awk '{print $2}' | tr -d '\r')"
  v2_v="$(grep -m1 -E '^version:' "$(to_native "$dst_md")" 2>/dev/null | awk '{print $2}' | tr -d '\r')"
  if [[ "$m1" == "$m2" && -n "$v1_v" && "$v1_v" == "$v2_v" ]]; then
    ok "V4 全局件一致（watchdog md5 相同，kanban-executor version=$v1_v）"
  else
    fail "V4 全局件不一致（watchdog md5 $([[ "$m1" == "$m2" ]] && echo 同 || echo 异)，SKILL version 仓库=${v1_v:-?} 全局=${v2_v:-?}）\
—— 修法：cp \"$(to_native "$src_wd")\" \"$(to_native "$dst_wd")\" && mkdir -p \"$(to_native "$HH/skills/devops")\" && rm -rf \"$(to_native "$HH/skills/devops/kanban-executor")\" && cp -r \"$(to_native "$REPO_ROOT/skills/kanban-executor")\" \"$(to_native "$HH/skills/devops/kanban-executor")\""
  fi
}

# ── V5 项目资产齐：五目录 + 制度层 + USAGE；角色库 11 / deprecated 5 ──
v5() {
  local missing=""
  local d
  for d in "Hermes模板库" "skills" "config" "scripts" "通用角色库"; do
    [[ -d "$PH/$d" ]] || missing="$missing $d/"
  done
  [[ -f "$PH/Hermes制度层.md" ]] || missing="$missing Hermes制度层.md"
  [[ -f "$PH/USAGE.md" ]] || missing="$missing USAGE.md"
  if [[ -n "$missing" ]]; then
    fail "V5 项目 .hermes/ 缺：$missing\
—— 修法：跑 DEPLOY.md §四 或 bootstrap-machine.sh --apply 重铺资产"
    return 0
  fi
  local n11 n5
  n11="$(find "$(to_native "$PH/通用角色库")" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')"
  n5="$(find "$(to_native "$PH/通用角色库/deprecated")" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$n11" -eq 11 && "$n5" -eq 5 ]]; then
    ok "V5 项目资产齐（五目录 + 制度层 + USAGE；通用角色库=$n11，deprecated=$n5）"
  else
    fail "V5 角色库数量不对：通用角色库=$n11（应 11），deprecated=$n5（应 5）\
—— 修法：rsync/cp 仓库 通用角色库/ → $(to_native "$PH/通用角色库/") 后，把顶层 5 个旧副本逐文件 rm -f（进 deprecated/，别整目录删）"
  fi
}

# ── V6 板名一致：wf.env 的 WF_BOARD == --board ──
v6() {
  if [[ ! -f "$WFE" ]]; then
    fail "V6 缺 $WFE\
—— 修法：bash scripts/bootstrap-machine.sh --project <项目> --board <板> --apply  # 生成 wf.env"
    return 0
  fi
  local wf_board
  wf_board="$(grep -E '^WF_BOARD=' "$(to_native "$WFE")" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '\r' | tr -d ' ')"
  # --board 显式传入：无论 wf.env 是否存在都以传入值为准继续跑，V7..V10 有确定性输出
  if [[ -n "$BOARD_ARG" ]]; then
    BOARD="$BOARD_ARG"
  fi
  # --board 未传：以 wf.env 为准（用作后续 V7..V10 的板名），只要非空即过
  if [[ -z "$BOARD_ARG" ]]; then
    if [[ -n "$wf_board" ]]; then
      BOARD="$wf_board"
      ok "V6 WF_BOARD=$wf_board（--board 未传，以 wf.env 为准）"
    else
      fail "V6 wf.env 缺 WF_BOARD 键或值为空\
—— 修法：echo 'WF_BOARD=<板>' >> '$(to_native "$WFE")'"
    fi
    return 0
  fi
  BOARD="$BOARD_ARG"
  if [[ "$wf_board" == "$BOARD_ARG" ]]; then
    ok "V6 板名一致（WF_BOARD=$wf_board == --board $BOARD_ARG）"
  else
    fail "V6 板名不一致：WF_BOARD=$wf_board ≠ --board $BOARD_ARG（哨兵会永远 total_ready=0）\
—— 修法：sed -i 's/^WF_BOARD=.*/WF_BOARD=$BOARD_ARG/' '$(to_native "$WFE")'  # 或改用 --board $wf_board"
  fi
}

v7() {
  if [[ -z "$BOARD" ]]; then
    fail "V7 看板探测无法跑（板名未知，wf.env 缺 WF_BOARD）\
—— 修法：修 V6 后重跑，或显式传 --board <板>"
    return 0
  fi
  local out rc
  out="$(timeout 30 "$HERMES_EXE" kanban boards </dev/null 2>&1)"
  rc=$?
  [[ $rc -eq 124 || $rc -eq 137 ]] && { fail "V7 看板探测 30s 未返回（该命令 30s 未返回，多半是 CLI 在等 stdin 或网关锁）\
—— 修法：timeout 30 $HERMES_EXE kanban boards </dev/null  # 手动复现确认"; return 0; }
  if _board_hit "$out" "$BOARD"; then
    ok "V7 看板存在：$BOARD"
  else
    fail "V7 看板 $BOARD 不存在\
—— 修法：$HERMES_EXE kanban board create $BOARD  # 或核对 slug 拼写"
  fi
}

v8() {
  if [[ -z "$BOARD" ]]; then
    fail "V8 cron 探测无法跑（板名未知）—— 修法：修 V6 后重跑"
    return 0
  fi
  local out rc
  out="$(timeout 30 "$HERMES_EXE" cron list </dev/null 2>&1)"
  rc=$?
  [[ $rc -eq 124 || $rc -eq 137 ]] && { fail "V8 cron 探测 30s 未返回（该命令 30s 未返回，多半是 CLI 在等 stdin 或网关锁）\
—— 修法：timeout 30 $HERMES_EXE cron list </dev/null  # 手动复现确认"; return 0; }
  if _board_hit "$out" "sentinel-$BOARD"; then
    ok "V8 哨兵 cron 已挂：sentinel-$BOARD"
  else
    fail "V8 缺哨兵 cron sentinel-$BOARD\
—— 修法：bash scripts/bootstrap-machine.sh --project <项目> --board $BOARD --apply --with-cron  # 生成包装壳并挂 cron"
  fi
}

# ── V9 哨兵真能跑：包装壳 rc=0 且 tick.log 末行 rc=0 ──
v9() {
  if [[ -z "$BOARD" ]]; then
    fail "V9 哨兵探测无法跑（板名未知）—— 修法：修 V6 后重跑"
    return 0
  fi
  local wrapper="$HH/scripts/sentinel-$BOARD.sh"
  if [[ ! -f "$wrapper" ]]; then
    fail "V9 缺哨兵包装壳：$(to_native "$wrapper")\
—— 修法：bash scripts/bootstrap-machine.sh --project <项目> --board <板> --apply --with-cron"
    return 0
  fi
  local rc last
  # 包装壳 120s 兜底：内部会跑 python 哨兵（再调 hermes CLI），链路长
  timeout 120 bash "$(to_native "$wrapper")" </dev/null >/dev/null 2>&1
  rc=$?
  if [[ $rc -eq 124 ]]; then
    fail "V9 哨兵包装壳 120s 未返回（该命令未返回，多半是 CLI 在等 stdin 或网关锁）\
—— 修法：timeout 120 bash '$(to_native "$wrapper")' </dev/null  # 手动复现确认"
    return 0
  fi
  last="$(last_nonempty "$(proj_log)")"
  if [[ $rc -eq 0 && "$last" == *rc=0* ]]; then
    ok "V9 哨兵可跑（rc=0；tick.log 末行：${last:0:80}）"
  else
    fail "V9 哨兵跑失败（包装壳 rc=$rc；tick.log 末行：${last:-<空>}）\
—— 修法：bash '$(to_native "$wrapper")'  # 手动跑看报错；再查包装壳是否 cd 到项目 .hermes/"
  fi
}

# ── V10 无死亡误报：watchdog 输出不含 SENTINEL_DEAD ──
v10() {
  if [[ -z "$BOARD" ]]; then
    fail "V10 watchdog 自检无法跑（板名未知）—— 修法：修 V6 后重跑"
    return 0
  fi
  local wd="$HH/scripts/kanban-watchdog.py"
  if [[ ! -f "$wd" ]]; then
    fail "V10 缺全局 watchdog，跑不了自检\
—— 修法：cp \"$(to_native "$REPO_ROOT/scripts/kanban-watchdog.py")\" \"$(to_native "$wd")\""
    return 0
  fi
  local out rc
  out="$(timeout 30 python "$(to_native "$wd")" --board "$BOARD" </dev/null 2>&1)"
  rc=$?
  [[ $rc -eq 124 || $rc -eq 137 ]] && { fail "V10 watchdog 自检 30s 未返回（该命令 30s 未返回，多半是 CLI 在等 stdin 或网关锁）\
—— 修法：timeout 30 python '$(to_native "$wd")' --board $BOARD </dev/null  # 手动复现确认"; return 0; }
  if ! grep -q 'SENTINEL_DEAD' <<<"$out"; then
    ok "V10 watchdog 无死亡误报"
  else
    fail "V10 watchdog 报 SENTINEL_DEAD（哨兵心跳缺失或过期）\
—— 修法：先手动跑一轮 bash '$(to_native "$HH/scripts/sentinel-$BOARD.sh")'，再查包装壳是否 touch '$(to_native "$HH")/logs/sentinel_state.json'"
  fi
}

# ── V11 冒烟（仅 --smoke）：plan-only：建卡 → 哨兵 --dry-run → 断言 → 归档 ──
v11() {
  if ! $SMOKE; then
    return 0
  fi
  if [[ -z "$BOARD" ]]; then
    fail "V11 冒烟无法跑（板名未知）—— 修法：修 V6 后重跑"
    return 0
  fi
  local title="[SMOKE] verify-deploy smoke test, delete me"
  local create_out
  create_out="$(timeout 30 "$HERMES_EXE" kanban --board "$BOARD" create "$title" \
    --assignee cc-backend-developer \
    --body 'smoke test card, self-cleaning via EXIT trap, delete me' </dev/null 2>&1)"
  local create_rc=$?
  [[ $create_rc -eq 124 || $create_rc -eq 137 ]] && { fail "V11 冒烟建卡 30s 未返回（该命令 30s 未返回，多半是 CLI 在等 stdin 或网关锁）\
—— 修法：手动跑 timeout 30 $HERMES_EXE kanban --board $BOARD create <标题> </dev/null 确认后再重跑 --smoke"; return 0; }
  # capture id：create 输出里的长 id 串；抓不到再从板列表按标题反查
  SMOKE_CARD_ID="$(grep -oE '[0-9a-fA-F-]{16,}' <<<"$create_out" | tail -1 || true)"
  if [[ -z "$SMOKE_CARD_ID" ]]; then
    SMOKE_CARD_ID="$(timeout 30 "$HERMES_EXE" kanban list </dev/null 2>/dev/null | grep -F "$title" | awk '{print $1}' | tail -1 || true)"
  fi
  # 冒烟只验证「哨兵能选中它」，绝不真 tick：真 tick 会拉起 claude lane，
  # 既烧 token 又可能改项目文件。--dry-run 只打印计划，不写 state、不调派单器、不动卡。
  local plan_out
  plan_out="$(timeout 30 python "$(to_native "$PH/scripts/card-sentinel.py")" --board "$BOARD" --dry-run </dev/null 2>&1)"
  if [[ -n "$SMOKE_CARD_ID" ]] && grep -Fq "$SMOKE_CARD_ID" <<<"$plan_out"; then
    ok "V11 冒烟通过（哨兵 plan-only 选中 SMOKE 卡：$(grep -m1 "$SMOKE_CARD_ID" <<<"$plan_out" | head -c 60)）"
  elif grep -Fq '[SMOKE]' <<<"$plan_out"; then
    ok "V11 冒烟通过（哨兵 plan-only 计划含 [SMOKE] 卡）"
  else
    fail "V11 冒烟：哨兵 --dry-run 计划里看不到 SMOKE 卡（卡 ID=${SMOKE_CARD_ID:-<空>}）\
—— 修法：手动跑 python '$(to_native "$PH/scripts/card-sentinel.py")' --board $BOARD --dry-run 看计划；\
若是 SKIP 类，核对卡的 status/assignee；卡清理见 EXIT trap"
  fi
}

# ════════════════════════════════════════════════════════════════
# 主流程
# ════════════════════════════════════════════════════════════════

# 板名定序：--board 优先；缺省经 V6 从 wf.env 读出并登记进 $BOARD。
# V6 前唯一依赖板名的是 v6 自己，故先跑 v6，再按 --board 是否显式传决定 V6 的断言方向。
echo "═══ 部署后能力验收 ═══"
echo "  项目：$(to_native "$PROJECT")"
echo "  看板：${BOARD_ARG:-<从 wf.env 读>}"
echo ""

v6
v1
v2
v3
v4
v5
v7
v8
v9
v10
v11

echo ""
echo "═══ 验收：$N_PASS 通过 / $N_FAIL 失败 ══（SKIP $N_SKIP 项）"
if [[ "$N_FAIL" -gt 0 ]]; then
  echo "有 FAIL 项：逐条按「修法」处理，再重跑本脚本。"
  exit 1
fi
exit 0
