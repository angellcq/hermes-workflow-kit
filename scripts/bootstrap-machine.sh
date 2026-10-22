#!/usr/bin/env bash
# bootstrap-machine.sh — 换机可部署（T-KIT-P7）
#
# 目标：在一台新机器上，只靠仓库 + 一条命令把这套全流程工作流装起来并让哨兵真的跑起来。
# 默认只探测打印 OK/WARN/FAIL 检查单；--apply 才落盘；全部动作幂等（目标已存在先备份）。
#
# 用法：
#   bash scripts/bootstrap-machine.sh --project D:/proj/a --board hljjt            # 只探测，打印检查单
#   bash scripts/bootstrap-machine.sh --project D:/proj/a --board hljjt --apply    # 落地
#   bash scripts/bootstrap-machine.sh --project D:/proj/a --board hljjt --apply --with-cron
#   bash scripts/bootstrap-machine.sh --check            # 无 --project 时的全局自检（不碰任何项目）
#
#   --project    可重复（一个项目一份 wf.env、可选一个哨兵 cron），必须配 --board
#   --with-cron  才建 cron（默认不建，避免"装完就自动跑"）
#   --apply      落地；缺省只探测
#
# 落地动作（幂等）：
#   1. 生成/补 <project>/.hermes/config/wf.env（不覆盖已有值，先备份 .wf.env.bak.<ts>）
#   2. bash scripts/install-claude-agents.sh（装 cc-* 角色到 CC agents 目录）
#   3. 拷全局件：kanban-watchdog.py → $HERMES_HOME/scripts/；
#      skills/kanban-executor/ → $HERMES_HOME/skills/devops/（目标已存在先 .bak.<ts>）
#   4. 建看板（不存在才建）
#   5. --with-cron：生成 $HERMES_HOME/scripts/sentinel-<board>.sh 包装壳并
#      hermes cron create "every 5m" --no-agent --name sentinel-<board> \
#        --script sentinel-<board>.sh --deliver local
#      （schedule 是位置参数；--script 只认 $HERMES_HOME/scripts/ 下的文件名，cron 不接受任意路径）
#
# 测试钩子：CC_AGENTS_DIR 环境变量可覆盖角色安装目录（默认 ~/.claude/agents），
# 供 tests/test_bootstrap.sh 隔离——绝不碰真实 ~/.claude/agents。
#
# Windows 路径铁律：凡拼给原生程序（python.exe/hermes.exe/git）的路径一律 C:/x/y，
# 统一走 to_native()（cygpath -m 可用则用），禁止 /c/x/y。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

to_native() { if command -v cygpath &>/dev/null; then cygpath -m "$1" 2>/dev/null || echo "$1"; else echo "$1"; fi; }

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ── 探测计数与输出 ────────────────────────────────────────────────
N_OK=0; N_WARN=0; N_FAIL=0
p_ok()   { N_OK=$((N_OK + 1));   echo "  OK   $*"; }
p_warn() { N_WARN=$((N_WARN + 1)); echo "  WARN $*"; }
p_fail() { N_FAIL=$((N_FAIL + 1)); echo "  FAIL $*"; }

# ── 参数解析 ─────────────────────────────────────────────────────
PROJECTS=()
BOARD=""
APPLY=false
WITH_CRON=false
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)   PROJECTS+=("$2"); shift 2 ;;
    --board)     BOARD="$2"; shift 2 ;;
    --apply)     APPLY=true; shift ;;
    --with-cron) WITH_CRON=true; shift ;;
    --check)     CHECK_ONLY=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
done

if [[ ${#PROJECTS[@]} -eq 0 ]]; then
  CHECK_ONLY=true   # 无 --project → 全局自检，不碰任何项目
elif [[ -z "$BOARD" ]]; then
  echo "✗ --project 必须配 --board（wf.env 的 WF_BOARD 要与板名一致，否则哨兵永远 total_ready=0）" >&2
  exit 2
fi
if $WITH_CRON && [[ -z "$BOARD" ]]; then
  echo "✗ --with-cron 必须配 --board（cron 名与包装壳都按板命名）" >&2
  exit 2
fi

# ── 探测：HERMES_HOME / hermes / python / bash / claude ─────────
echo "══ 全局探测 ══"

if [[ -n "${HERMES_HOME:-}" ]]; then
  HH="$HERMES_HOME"
else
  # 缺省：Windows 用 $LOCALAPPDATA/hermes，其余 ~/.hermes
  if [[ -n "${LOCALAPPDATA:-}" ]]; then HH="$LOCALAPPDATA/hermes"; else HH="$HOME/.hermes"; fi
fi

# 硬条件只有三类：HERMES_HOME 不可写/不可创建、项目 .hermes/ 缺目录、板名 MISMATCH。其余一律 WARN。
if [[ -d "$HH" && -w "$HH" ]]; then
  p_ok "HERMES_HOME=$HH"
elif [[ -d "$HH" ]]; then
  p_fail "HERMES_HOME 不可写：$HH —— 修法：检查目录权限（被占用/只读），或 export HERMES_HOME=可写路径"
elif [[ -w "$(dirname "$HH")" ]]; then
  p_warn "HERMES_HOME 不存在：$HH —— --apply 会自动创建"
else
  p_fail "HERMES_HOME 不存在且父目录不可写：$HH —— 修法：export HERMES_HOME=可写路径，或检查父目录权限"
fi

# hermes 可执行：which 优先，兜底 $HERMES_HOME/installs/*/environments/*/venv/Scripts/hermes.exe
HERMES_EXE=""
_c="$(command -v hermes 2>/dev/null || true)"
if [[ -n "$_c" ]]; then
  HERMES_EXE="$(to_native "$_c")"
  p_ok "hermes 可执行：$HERMES_EXE"
else
  for _g in "$HH"/installs/*/environments/*/venv/Scripts/hermes.exe; do
    if [[ -f "$_g" ]]; then HERMES_EXE="$(to_native "$_g")"; break; fi
  done
  if [[ -n "$HERMES_EXE" ]]; then
    p_ok "hermes 可执行（venv 探测）：$HERMES_EXE"
  else
    p_fail "找不到 hermes —— 修法：装 Hermes 桌面端/CLI，或 export HERMES_HOME=安装根目录"
  fi
fi
# 测试/改机钩子：HERMES_BIN 显式指定 hermes 可执行路径，优先于上面的自动探测——
# 脚本内所有 hermes 调用都走 $HERMES_EXE，测试注入的假 hermes 必须经此钩子才能接管
HERMES_EXE="${HERMES_BIN:-$HERMES_EXE}"

# python：同 hermes 策略；which 命中的若是 MSYS 形式（/c/...）必须归一成 C:/...（原生程序不认）
PY_EXE=""
_c="$(command -v python 2>/dev/null || command -v python3 2>/dev/null || true)"
if [[ -n "$_c" ]]; then
  PY_EXE="$(to_native "$_c")"
  p_ok "python：$PY_EXE"
else
  for _g in "$HH"/installs/*/environments/*/venv/Scripts/python.exe; do
    if [[ -f "$_g" ]]; then PY_EXE="$(to_native "$_g")"; break; fi
  done
  if [[ -n "$PY_EXE" ]]; then
    p_ok "python（venv 探测）：$PY_EXE"
  else
    p_fail "找不到 python —— 修法：装 Python 并确保在 PATH（注意 Windows Store 存根不算）"
  fi
fi

# bash：优先 Hermes 自带 git-bash，兜底当前 shell 的 bash
BASH_EXE=""
for _g in "$HH"/tools/git-*/usr/bin/bash.exe; do
  if [[ -f "$_g" ]]; then BASH_EXE="$(to_native "$_g")"; break; fi
done
if [[ -z "$BASH_EXE" ]]; then
  _c="$(command -v bash 2>/dev/null || echo /usr/bin/bash)"
  BASH_EXE="$(to_native "$_c")"
fi
p_ok "bash：$BASH_EXE"

# claude：--version ≥ 2.1.300（低于则 WARN：--agent 不可用）
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }
CLAUDE_VER="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [[ -z "$CLAUDE_VER" ]]; then
  p_warn "claude 不可用/未找到 —— 修法：装 Claude Code ≥2.1.300，否则 --agent 调不到角色"
elif ver_ge "$CLAUDE_VER" "2.1.300"; then
  p_ok "claude $CLAUDE_VER ≥ 2.1.300（--agent 可用）"
else
  p_warn "claude $CLAUDE_VER < 2.1.300：--agent 不可用 —— 修法：升级 Claude Code"
fi

# CC agents 目录：统计 cc-*.md，期望 11（目录不存在 ≡ 0 个；WARN 不阻止 --apply——install 脚本会建目录装齐）
AGENTS_DIR="${CC_AGENTS_DIR:-$HOME/.claude/agents}"
AGENTS_SHOW="$(to_native "$AGENTS_DIR")"
_n="$(find "$AGENTS_DIR" -maxdepth 1 -name 'cc-*.md' -type f 2>/dev/null | wc -l)"
if [[ "$_n" -eq 11 ]]; then
  p_ok "CC agents：$AGENTS_SHOW 下 cc-*.md 共 $_n 个（期望 11）"
else
  p_warn "CC agents：$AGENTS_SHOW 下 cc-*.md 共 $_n 个（期望 11）—— 修法：bash scripts/install-claude-agents.sh（--apply 自动装）"
fi

# ── 探测：全局件（watchdog 副本 / 全局技能 / 全局心跳）──────────
SRC_WATCHDOG="$ROOT/scripts/kanban-watchdog.py"
DST_WATCHDOG="$HH/scripts/kanban-watchdog.py"
if [[ -f "$DST_WATCHDOG" && -f "$SRC_WATCHDOG" ]] \
   && [[ "$(md5sum "$DST_WATCHDOG" | cut -d' ' -f1)" == "$(md5sum "$SRC_WATCHDOG" | cut -d' ' -f1)" ]]; then
  p_ok "全局 watchdog：$DST_WATCHDOG（与仓库副本 md5 一致）"
elif [[ -f "$DST_WATCHDOG" ]]; then
  p_warn "全局 watchdog 与仓库副本 md5 不一致（旧版）—— --apply 会先备份再覆盖：$DST_WATCHDOG"
else
  p_warn "缺全局 watchdog：$DST_WATCHDOG —— --apply 会从仓库拷贝（HOME 级，cron 要求脚本在 HERMES_HOME/scripts 下）"
fi

DST_SKILL="$HH/skills/devops/kanban-executor/SKILL.md"
if [[ -f "$DST_SKILL" ]]; then
  p_ok "全局技能副本：$DST_SKILL"
else
  p_warn "缺全局技能副本：$DST_SKILL —— --apply 会从仓库 skills/kanban-executor/ 拷贝"
fi

if [[ -f "$HH/logs/sentinel_state.json" ]]; then
  p_ok "全局心跳：$HH/logs/sentinel_state.json 存在"
else
  p_warn "无全局心跳：$HH/logs/sentinel_state.json 不存在（还没 tick 过或没补心跳；--with-cron 的包装壳会在 tick 成功后 touch）"
fi

# ── 探测：看板 / cron（需要 --board 且 hermes 可用）──────────────
if [[ -n "$BOARD" ]]; then
  if [[ -z "$HERMES_EXE" ]]; then
    p_fail "看板探测跳过：hermes 不可用"
  else
    _boards="$("$HERMES_EXE" kanban boards 2>/dev/null || true)"
    # grep 加左右边界（非名字字符），防 hljjt 误命中 hljjt_x 等前缀重叠的板名
    if echo "$_boards" | grep -Eq "(^|[^a-zA-Z0-9_-])${BOARD}([^a-zA-Z0-9_-]|$)"; then
      p_ok "看板 $BOARD 存在"
    else
      p_warn "看板 $BOARD 不存在 —— 修法：hermes kanban board create $BOARD（--apply 自动建）"
    fi
    _cron="$("$HERMES_EXE" cron list 2>/dev/null || true)"
    if echo "$_cron" | grep -Eq "(^|[^a-zA-Z0-9_-])sentinel-${BOARD}([^a-zA-Z0-9_-]|$)"; then
      p_ok "cron sentinel-$BOARD 已挂"
    else
      p_warn "cron sentinel-$BOARD 未挂 —— 修法：hermes cron create \"every 5m\" --no-agent --name sentinel-$BOARD --script sentinel-$BOARD.sh --deliver local（--apply --with-cron 自动建）"
    fi
  fi
fi

# ── 探测：项目 .hermes/ 与 wf.env ────────────────────────────────
for PROJ in "${PROJECTS[@]}"; do
  echo "══ 项目探测：$PROJ ══"
  PH="$PROJ/.hermes"
  if [[ ! -d "$PH" ]]; then
    p_fail "项目 .hermes/ 目录不存在：$PH —— 修法：跑 DEPLOY.md §四（铺项目 .hermes/）；--apply 只建 config/ 不铺全套"
  else
    _miss=""
    for _d in "Hermes模板库" "skills" "config" "scripts" "通用角色库"; do
      [[ -d "$PH/$_d" ]] || _miss="$_miss $_d/"
    done
    [[ -f "$PH/Hermes制度层.md" ]] || _miss="$_miss Hermes制度层.md"
    if [[ -z "$_miss" ]]; then
      p_ok "项目 .hermes/ 五目录 + 制度层齐全"
    else
      p_fail "项目 .hermes/ 缺：$_miss —— 修法：跑 DEPLOY.md §四（铺项目 .hermes/）"
    fi
  fi

  WFE="$PH/config/wf.env"
  if [[ -f "$WFE" ]]; then
    _wb="$(grep -E '^WF_BOARD=' "$WFE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d ' ' | tr -d '\r')"
    if [[ "$_wb" == "$BOARD" ]]; then
      p_ok "wf.env：WF_BOARD=$_wb 与 --board 一致"
    else
      p_fail "板名不匹配（MISMATCH）：$WFE 的 WF_BOARD=$_wb ≠ --board $BOARD —— 哨兵会永远 total_ready=0；修法：改 wf.env 的 WF_BOARD=$BOARD，或改用 --board $_wb"
    fi
  else
    p_warn "wf.env 不存在：$WFE —— --apply 会按 config/wf.env.example 生成"
  fi
done

# ── 探测结束：检查单汇总 ─────────────────────────────────────────
echo ""
echo "═══ 检查结果：OK=$N_OK WARN=$N_WARN FAIL=$N_FAIL ═══"
if [[ "$N_FAIL" -gt 0 ]]; then
  echo "有 FAIL 项（硬条件）：先按上面各条「修法」处理，再重跑本脚本。WARN 不阻止 --apply。"
fi

$CHECK_ONLY && { [[ "$N_FAIL" -eq 0 ]] && exit 0 || exit 1; }

# ════════════════════════════════════════════════════════════════
# --apply 落地（全部幂等）
# ════════════════════════════════════════════════════════════════
echo ""
echo "══ --apply 落地 ══"

# 硬护栏：只有硬条件 FAIL 才止步（.hermes/ 缺目录、板名 MISMATCH、HERMES_HOME 不可写/不可创建）。
# claude 缺失、agents 数不对、看板/cron/心跳缺失、watchdog md5 不一致都是 WARN——--apply 会补齐。
if [[ "$N_FAIL" -gt 0 ]]; then
  echo "✗ 探测有 $N_FAIL 个硬条件 FAIL（见检查单各条的「修法」），已止步不落盘。"
  echo "  修完重跑：bash scripts/bootstrap-machine.sh --project <项目> --board <板> --apply"
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"

if [[ ! -d "$HH" ]]; then
  echo "[apply] HERMES_HOME 不存在，创建：$HH"
  mkdir -p "$HH" || { echo "✗ 无法创建 $HH —— 修法：检查磁盘/权限后重跑本脚本"; exit 1; }
fi

# ── 动作 1：wf.env 生成/补键（per project，先于其他动作）────────
# 探测模式（无 --apply）绝不落盘：写盘分支整段包进 if $APPLY；板名 MISMATCH 的
# 检测在前面探测段已 p_fail，不依赖此处的写盘逻辑。
if $APPLY; then
for PROJ in "${PROJECTS[@]}"; do
  WFE="$PROJ/.hermes/config/wf.env"
  PROJ_N="$(to_native "$PROJ")"
  if [[ -f "$WFE" ]]; then
    _wb="$(grep -E '^WF_BOARD=' "$WFE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d ' ' | tr -d '\r')"
    if [[ "$_wb" != "$BOARD" ]]; then
      echo "[apply] ✗ 跳过 wf.env（板名不匹配，见探测项；绝不覆盖你的 WF_BOARD）：$WFE"
      continue
    fi
    cp "$WFE" "${WFE%/*}/.wf.env.bak.$TS"
    echo "[apply] wf.env 已备份：.wf.env.bak.$TS，开始补缺失键（不覆盖已有值）"
    _block="$(mktemp)"
    while IFS= read -r _line; do
      _line="${_line%$'\r'}"                   # 样例可能是 CRLF（Windows 检出），去尾 \r 防污染键值
      [[ "$_line" == WF_* ]] || continue       # 只补键值行，注释与空行跳过
      _key="${_line%%=*}"
      _val="${_line#*=}"
      [[ -n "$_val" ]] || continue             # 样例里为空的键不补
      grep -qE "^${_key}=" "$WFE" && continue  # 用户已有该键 → 不动（= 前缀匹配，兼容行尾 \r）
      case "$_key" in
        WF_BOARD)  echo "WF_BOARD=$BOARD" >> "$_block" ;;
        WF_REPO)   echo "WF_REPO=$PROJ_N" >> "$_block" ;;
        WF_PYTHON) echo "WF_PYTHON=$PY_EXE" >> "$_block" ;;
        WF_BASH)   echo "WF_BASH=$BASH_EXE" >> "$_block" ;;
        *)         echo "$_line" >> "$_block" ;;
      esac
    done < "$ROOT/config/wf.env.example"
    if [[ -s "$_block" ]]; then
      { echo "# ── 以下由 bootstrap-machine.sh 于 $TS 自动补齐 ──"; cat "$_block"; } >> "$WFE"
    else
      echo "[apply] wf.env 无缺失键，内容未改动"
    fi
    rm -f "$_block"
  else
    mkdir -p "${WFE%/*}"
    sed -E \
      -e "s|^WF_BOARD=.*|WF_BOARD=${BOARD}|" \
      -e "s|^WF_REPO=.*|WF_REPO=${PROJ_N}|" \
      -e "s|^WF_PYTHON=.*|WF_PYTHON=${PY_EXE}|" \
      -e "s|^WF_BASH=.*|WF_BASH=${BASH_EXE}|" \
      "$ROOT/config/wf.env.example" | tr -d '\r' > "$WFE"   # 样例若是 CRLF 检出，去 \r 防值被污染成 board\r
    echo "[apply] wf.env 已生成：$WFE（板名 + 三条本机路径已填）"
  fi
done
else
  # 探测模式：只打印将要动到的文件，绝不写盘
  for PROJ in "${PROJECTS[@]}"; do
    echo "[dry-run] 将生成/补齐 $PROJ/.hermes/config/wf.env（--apply 才写盘）"
  done
fi

# 探测模式到此为止：动作 2/3/4/5 全是写盘动作，无 --apply 不许再往下走
if ! $APPLY; then
  echo "[dry-run] 探测模式：仅打印检查单，未落盘（动作 2~5 需 --apply）"
  exit 0
fi

# ── 动作 2：装 CC agents（幂等，已有脚本直接调）─────────────────
if [[ -f "$ROOT/scripts/install-claude-agents.sh" ]]; then
  echo "[apply] 装 CC agents → $AGENTS_DIR"
  if ! bash "$ROOT/scripts/install-claude-agents.sh" --dir "$AGENTS_DIR"; then
    echo "✗ install-claude-agents.sh 失败 —— 修法：手动跑 bash scripts/install-claude-agents.sh 看具体报错"
  fi
else
  echo "✗ 找不到 $ROOT/scripts/install-claude-agents.sh —— 修法：确认仓库完整（git pull）"
fi

# ── 动作 3：拷全局件（watchdog + kanban-executor 技能副本）──────
if [[ -f "$SRC_WATCHDOG" ]]; then
  if [[ -f "$DST_WATCHDOG" ]] \
     && [[ "$(md5sum "$DST_WATCHDOG" | cut -d' ' -f1)" != "$(md5sum "$SRC_WATCHDOG" | cut -d' ' -f1)" ]]; then
    cp "$DST_WATCHDOG" "$DST_WATCHDOG.bak.$TS"
    echo "[apply] 旧 watchdog 已备份：kanban-watchdog.py.bak.$TS"
  fi
  mkdir -p "$HH/scripts"
  if cmp -s "$SRC_WATCHDOG" "$DST_WATCHDOG" 2>/dev/null; then
    echo "[apply] watchdog 已是最新，跳过"
  else
    cp "$SRC_WATCHDOG" "$DST_WATCHDOG"
    echo "[apply] watchdog 已拷：$DST_WATCHDOG"
  fi
else
  echo "✗ 仓库缺 $SRC_WATCHDOG —— 修法：确认仓库完整（git pull）"
fi

SRC_SKILL="$ROOT/skills/kanban-executor"
DST_SKILL_DIR="$HH/skills/devops/kanban-executor"
if [[ -d "$SRC_SKILL" ]]; then
  if [[ -f "$DST_SKILL_DIR/SKILL.md" ]] \
     && [[ "$(md5sum "$DST_SKILL_DIR/SKILL.md" | cut -d' ' -f1)" == "$(md5sum "$SRC_SKILL/SKILL.md" | cut -d' ' -f1)" ]]; then
    echo "[apply] 全局技能副本已是最新，跳过"
  else
    if [[ -d "$DST_SKILL_DIR" ]]; then
      mv "$DST_SKILL_DIR" "$DST_SKILL_DIR.bak.$TS"
      echo "[apply] 旧技能副本已备份：kanban-executor.bak.$TS"
    fi
    mkdir -p "$HH/skills/devops"
    cp -r "$SRC_SKILL" "$DST_SKILL_DIR"
    echo "[apply] 全局技能副本已拷：$DST_SKILL_DIR"
  fi
else
  echo "✗ 仓库缺 $SRC_SKILL —— 修法：确认仓库完整（git pull）"
fi

# ── 动作 4+5：建看板 / 哨兵包装壳 + cron（per project）──────────
for PROJ in "${PROJECTS[@]}"; do
  # 动作 4：建看板（不存在才建）
  if [[ -n "$HERMES_EXE" ]]; then
    _boards="$("$HERMES_EXE" kanban boards 2>/dev/null || true)"
    if echo "$_boards" | grep -q "$BOARD"; then
      echo "[apply] 看板 $BOARD 已存在，跳过"
    else
      echo "[apply] 建看板：hermes kanban board create $BOARD"
      if ! "$HERMES_EXE" kanban board create "$BOARD"; then
        echo "✗ 建看板失败 —— 修法：手动跑 hermes kanban board create $BOARD"
      fi
    fi
  else
    echo "✗ hermes 不可用，建不了看板 —— 修法：装好 Hermes 后手动跑 hermes kanban board create $BOARD"
  fi

  # 动作 5：哨兵包装壳 + cron（--with-cron 才做）
  if $WITH_CRON; then
    WRAPPER="$HH/scripts/sentinel-$BOARD.sh"
    if [[ -f "$WRAPPER" ]]; then
      cp "$WRAPPER" "$WRAPPER.bak.$TS"
      echo "[apply] 旧包装壳已备份：sentinel-$BOARD.sh.bak.$TS"
    fi
    mkdir -p "$HH/scripts"
    cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
# 哨兵 cron 包装壳（由 bootstrap-machine.sh 生成于 $TS）——别手工编辑，重跑 bootstrap 会重新生成
PROJ_HERMES="$(to_native "$PROJ")/.hermes"
HERMES_HOME="\${HERMES_HOME:-$(to_native "$HH")}"
PY="$PY_EXE"
cd "\$PROJ_HERMES" || { echo "哨兵跳过：\$PROJ_HERMES 不存在"; exit 0; }
\$PY scripts/sentinel_tick.py "\$@"
rc=\$?
# 全局心跳：全局 watchdog 只看 \$HERMES_HOME/logs/sentinel_state.json 的 mtime
if [ "\$rc" -eq 0 ]; then mkdir -p "\$HERMES_HOME/logs"; touch "\$HERMES_HOME/logs/sentinel_state.json"; fi
exit "\$rc"
WRAP
    echo "[apply] 包装壳已生成：$WRAPPER"
    _cron="$("$HERMES_EXE" cron list 2>/dev/null || true)"
    if echo "$_cron" | grep -q "sentinel-$BOARD"; then
      echo "[apply] cron sentinel-$BOARD 已挂，跳过"
    else
      echo "[apply] 挂 cron：hermes cron create \"every 5m\" --no-agent --name sentinel-$BOARD --script sentinel-$BOARD.sh --deliver local"
      if ! "$HERMES_EXE" cron create "every 5m" --no-agent --name "sentinel-$BOARD" --script "sentinel-$BOARD.sh" --deliver local; then
        echo "✗ 挂 cron 失败 —— 修法：手动跑 hermes cron create \"every 5m\" --no-agent --name sentinel-$BOARD --script sentinel-$BOARD.sh --deliver local（schedule 是位置参数；--script 只认 \$HERMES_HOME/scripts/ 下的文件名）"
      fi
    fi
  fi
done

# ── 收尾：接下来手工做的 3 件事 ──────────────────────────────────
echo ""
echo "══ bootstrap 完成：OK=$N_OK WARN=$N_WARN FAIL=$N_FAIL ══"
echo "接下来手工做 3 件事："
echo "  1. 给 6 个项目铺 .hermes/（DEPLOY.md §四：五目录 + 制度层 + 单文件）"
echo "  2. 写项目 AGENTS.md §7 工作流入口（DEPLOY.md「接线入口」一节，原样追加）"
echo "  3. 重启 Hermes（桌面端/网关/CLI），让 cron 生效"

[[ "$N_FAIL" -eq 0 ]] && exit 0 || exit 1
