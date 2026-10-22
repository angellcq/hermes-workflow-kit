#!/usr/bin/env bash
# dispatch-lane.sh — 派单器：守卫硬实现 + 三态产出校验（T-KIT-P2）
#
# 用法:
#   bash dispatch-lane.sh <task_id> <agent_or_role> "<prompt>" [project_dir] [board]
#
# 环境变量（缺省取 wf.env 同名键）:
#   FORCE_DISPATCH=1      跳过守卫②③
#   SKIP_PRODUCE_CHECK=1  收尾直接 complete（透传给 card_check.py）
#
# 退出码: 0 成功完成 / 1 产出校验未通过(已 block) / 2 参数或环境错误
#         / 3 守卫拒绝派单 / 其他=底层 claude 退出码
#
# 为什么有这个脚本：kit 过去的派单是"会话里手工敲 claude -p"，三个实测问题——
#   1) 派单不收尾（零产出被当完成，改动躺在工作区被下一个 worker 覆盖）
#   2) claim 静默失败无人知（工人空转，卡被再派一次，双写同一份文件）
#   3) 角色没真加载（只写进 TASK.md 文本）
# 本脚本把 1)、2) 从文字规则变成代码；3) 只做接口预留（P4 切 claude --agent）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ════════════════════════════════════════════════════════════════
# 配置加载（wf.env 缺省键位 → 环境变量覆盖）
# ════════════════════════════════════════════════════════════════

WF_ENV_FILE="${WF_ENV_FILE:-$SCRIPT_DIR/../config/wf.env}"
# shellcheck disable=SC1090
[[ -f "$WF_ENV_FILE" ]] && . "$WF_ENV_FILE"

WF_BOARD="${WF_BOARD:-}"
WF_AGENT_PREFIX="${WF_AGENT_PREFIX:-cc-}"
WF_CLAUDE_ARGS="${WF_CLAUDE_ARGS:---allowedTools Bash,Read,Write,Edit,MultiEdit,Grep,Glob}"
WF_MAX_OUTPUT_TOKENS="${WF_MAX_OUTPUT_TOKENS:-32000}"
WF_PYTHON="${WF_PYTHON:-}"
WF_HERMES="${WF_HERMES:-hermes}"
# claude 可执行可注入（tests/test_dispatch_guards.sh 用假执行器替身）
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

log()  { echo "[$(date +%H:%M:%S)] $*" >&2; }
warn() { echo "[$(date +%H:%M:%S)] ⚠ $*" >&2; }
err()  { echo "[$(date +%H:%M:%S)] ✗ $*" >&2; }

usage() {
  cat >&2 <<'EOF'
用法: bash dispatch-lane.sh <task_id> <agent_or_role> "<prompt>" [project_dir] [board]

  <task_id>       看板卡号（hermes kanban 卡 id，如 t_xxxx）
  <agent_or_role> 工人角色名（自动补 WF_AGENT_PREFIX 前缀）
  "<prompt>"      派单提示词（写入 TASK.md）
  [project_dir]   目标 git 仓库绝对路径（缺省取 WF_REPO）
  [board]         看板板名（缺省取 WF_BOARD；两处都空 → 参数错误 exit 2）

环境变量:
  FORCE_DISPATCH=1      跳过守卫②③（双重派单/claim 复核）
  SKIP_PRODUCE_CHECK=1  收尾直接 complete（透传给 card_check.py）

退出码: 0 成功完成 / 1 产出校验未通过(已 block) / 2 参数或环境错误
        / 3 守卫拒绝派单 / 其他=底层 claude 退出码
EOF
}

# ════════════════════════════════════════════════════════════════
# python 探测（wf.env 的 WF_PYTHON 可能是 Store 存根，要真跑一次验证）
# ════════════════════════════════════════════════════════════════

find_py() {
  local cand
  # 显式配置优先，但必须真跑一次：Windows 的 python3 可能是 Microsoft Store
  # 存根——存在于 PATH、执行却只弹商店/静默退出，用它跑 card_check.py 会
  # 拿到空快照，产出校验整条静默失效。
  for cand in "$WF_PYTHON" python python3; do
    [[ -z "$cand" ]] && continue
    if "$cand" -c "import sys" >/dev/null 2>&1; then
      echo "$cand"; return 0
    fi
    # 只在显式配置坏掉时警告一次
    if [[ "$cand" == "$WF_PYTHON" ]]; then
      warn "WF_PYTHON=$WF_PYTHON 无法执行（可能是 Store 存根），回退自动探测"
    fi
  done
  return 1
}

# 把 MSYS 形式路径转成原生 python 认的形态（C:/...）。
# 这是实测事故：git-bash 里 $SCRIPT_DIR 是 /c/Users/... 形式，$PY_BIN 是原生
# Windows python——原生解释器打不开 /c/... 的**脚本**路径（输出为空、退出码
# 还可能是 0），守卫④快照静默变空 → 降级"不做产出校验" → 三态校验整条失效。
# 有 cygpath 用 cygpath -m（正斜杠混合盘符，python/os 都认）；没有就用
# python 侧 wf_common.native_path（与被测代码同一实现）兜底。
py_native_path() {
  local p="$1"
  if command -v cygpath &>/dev/null; then
    cygpath -m "$p"
  elif [[ -n "$PY_BIN" ]]; then
    "$PY_BIN" -c "import sys; sys.path.insert(0, r'''$SCRIPT_DIR'''); import wf_common; print(wf_common.native_path(sys.argv[1]))" "$p" 2>/dev/null || echo "$p"
  else
    echo "$p"
  fi
}

# 卡状态查询：stdout = 状态名（todo/ready/running/blocked/done/...），失败返回 1
card_status() {
  local id="$1" board="$2"
  local out
  out="$("$WF_HERMES" kanban --board "$board" show "$id" 2>/dev/null | sed -n 's/^  status:[[:space:]]*//p' | head -1 | tr -d '[:space:]')" || return 1
  [[ -z "$out" ]] && return 1
  echo "$out"
}

# 卡标题查询：stdout = 标题（供 EMPTY 评论用），失败返回空串
card_title() {
  "$WF_HERMES" kanban --board "$1" show "$2" 2>/dev/null | sed -n 's/^Task [^:]*:[[:space:]]*//p' | head -1
}

# ════════════════════════════════════════════════════════════════
# 主流程
# ════════════════════════════════════════════════════════════════

main() {
  local task_id="${1:-}" agent_in="${2:-}" prompt="${3:-}" project_dir="${4:-}" board="${5:-}"

  # ---- 参数检查（exit 2 = 参数或环境错误）----
  if [[ $# -lt 3 || -z "$task_id" || -z "$agent_in" ]]; then
    usage
    return 2
  fi
  [[ -z "$board" ]] && board="$WF_BOARD"
  [[ -z "$board" ]] && { err "板名必填：第 5 参数或 WF_BOARD（守卫①：kanban/current 是全局指针，会随别的项目漂移，曾出现 claim 打到别的板）"; return 2; }
  [[ -z "$project_dir" ]] && project_dir="${WF_REPO:-}"
  [[ -z "$project_dir" ]] && { err "project_dir 必填：第 4 参数或 WF_REPO（产出校验依赖 git 快照）"; return 2; }

  if ! PY_BIN="$(find_py)"; then
    err "找不到可用的 python（WF_PYTHON 也无效）"
    return 2
  fi

  # 判定器脚本路径转原生形态（原因见 py_native_path 注释）。$SCRIPT_DIR 在
  # git-bash 里是 /c/Users/... 形式，原生 python 打不开 → 快照静默变空。
  local CARD_CHECK_PY
  CARD_CHECK_PY="$(py_native_path "$SCRIPT_DIR/card_check.py")"

  # ---- 工人名规范化：不带前缀自动补 WF_AGENT_PREFIX ----
  # 兼容传 backend-developer（D1 裁决：assignee=路由键，前缀是防抢单机制——
  # 真 profile 名会被网关 dispatcher 抢单）。
  local agent_name="$agent_in"
  if [[ -n "$WF_AGENT_PREFIX" && "$agent_name" != "$WF_AGENT_PREFIX"* ]]; then
    agent_name="${WF_AGENT_PREFIX}${agent_name}"
  fi

  # ═══ 守卫①：全程显式 --board ═══
  # kanban/current 是全局指针，会随别的项目漂移；不带 --board 的 claim 曾
  # 静默打到别的板。本脚本所有 kanban 子命令一律显式 --board "$BOARD"，
  # 且板名必填（上面已挡）。
  local BOARD="$board"

  # ═══ 守卫②：claim 前查状态 ═══
  # 挡"网关 dispatcher 已派人 + 你手动再派一个"的双写：卡已是 running 说明
  # 有工人在跑，再派就是两个 worker 写同一份文件。
  local st_before
  if ! st_before="$(card_status "$task_id" "$BOARD")"; then
    err "取不到卡 $task_id 的状态（show 失败），拒绝派单"
    return 3
  fi
  if [[ "$st_before" == "running" && "${FORCE_DISPATCH:-0}" != "1" ]]; then
    warn "卡 $task_id 已是 running（可能有 worker 在跑），拒绝重复派单；确认无误可 FORCE_DISPATCH=1 重派"
    return 3
  fi

  # ═══ 守卫③：claim 后复核 ═══
  # claim 会静默失败（输出被丢弃时"命令跑完了，什么都没发生"）→
  # 「worker 在跑、看板显示 todo」→ 卡被再派一次。所以 unblock + claim 后
  # 必须重查状态，非 running 一律视为 claim 失败，把真实原因亮出来。
  if [[ "$st_before" != "running" || "${FORCE_DISPATCH:-0}" != "1" ]]; then
    "$WF_HERMES" kanban --board "$BOARD" unblock "$task_id" \
      --reason "dispatch-lane 重派前解阻" >/dev/null 2>&1 || true
  fi
  local claim_out claim_rc
  # claim 输出必须捕获带回（静默失败的表现就是输出被丢弃后无人看真实原因）
  claim_out="$("$WF_HERMES" kanban --board "$BOARD" claim "$task_id" --ttl 7200 2>&1)" && claim_rc=0 || claim_rc=$?
  log "claim: $claim_out"

  local st_after
  st_after="$(card_status "$task_id" "$BOARD" || true)"
  if [[ "$st_after" != "running" && "${FORCE_DISPATCH:-0}" != "1" ]]; then
    # 多半是父卡未完成（依赖未满足，claim 被状态机顶回），把真实状态亮给操作员
    err "claim 后状态仍为 ${st_after:-未知}（claim ${claim_rc}）：$claim_out"
    err "多半是父卡未完成或依赖未满足；确认依赖已收口后重试，或 FORCE_DISPATCH=1 硬派"
    return 3
  fi

  # ═══ 守卫④：派单前快照 ═══
  # 路径先过 native_path 转换（git-bash 的 /d/tmp 传给原生 python 会
  # chdir 失败 NotADirectoryError——转换在 python 侧 wf_common.native_path 做）。
  # 取不到快照时明确警告并标记本次"不做产出校验"（fail-open 但留痕），
  # 因为没基准线就没法比；真正的 fail-closed 在收尾侧兜（判定异常→评论）。
  local snap_before="" no_check=""
  snap_before="$("$PY_BIN" "$CARD_CHECK_PY" snapshot "$project_dir" 2>/dev/null)" || true
  if [[ ! "$snap_before" =~ ^[0-9a-f]+[[:space:]] || "$snap_before" != *$'\t'* ]]; then
    warn "取不到派单前快照（card_check snapshot 失败），本次派单将不做产出校验"
    no_check=1
    snap_before=""
  fi

  # ---- 写 TASK.md（防空任务：worker 的启动指令只有"读 TASK.md 并执行"）----
  local tmpdir task_md
  tmpdir="$(mktemp -d)"
  task_md="$tmpdir/TASK.md"
  cat > "$task_md" <<EOF
# 任务

$prompt

## 角色
$agent_name

## 工作目录
$project_dir

## 任务卡
$task_id（板：$BOARD）
EOF

  # ═══ 守卫⑤：默认注入工具白名单 + 输出上限 ═══
  # WF_CLAUDE_ARGS 默认 --allowedTools 逗号分隔（空格分隔无效！实测空格写法
  # 会导致工人第一步 Bash 被权限墙拒、静默空转、返回 exit=0 假成功）。
  # CLAUDE_CODE_MAX_OUTPUT_TOKENS 默认 2048 会截断长报告并崩，这里抬到 32000。
  export CLAUDE_CODE_MAX_OUTPUT_TOKENS="${WF_MAX_OUTPUT_TOKENS:-32000}"

  log "派单 [task=$task_id agent=$agent_name board=$BOARD workdir=$project_dir]"
  # 说明：这里仍走 `claude -p`（角色名只进 TASK.md 文本），真加载要等 P4 切
  # `claude --agent <agent_name>`——现在 ~/.claude/agents/ 里还没有 cc-* profile。
  "$CLAUDE_BIN" -p "读 $task_md 并执行。完成后输出修改文件清单与 diff 摘要。" \
    $WF_CLAUDE_ARGS \
    --output-format json
  local worker_rc=$?

  rm -rf "$tmpdir"

  # ═══ 守卫⑥：三态产出校验收尾 ═══
  # claude 底层退出码 ≠ 0：worker 没跑完，不存在"校验产出"，直接 block 并透传。
  # 挡"worker 崩了但脚本当成成功收尾"。
  if [[ "$worker_rc" -ne 0 ]]; then
    "$WF_HERMES" kanban --board "$BOARD" block "$task_id" \
      "lane($agent_name) 失败 exit=$worker_rc，详见 worker 日志" >/dev/null 2>&1 || true
    log "worker 失败（exit=$worker_rc），卡已 block"
    return "$worker_rc"
  fi

  # SKIP_PRODUCE_CHECK=1：操作员显式跳过校验（透传给 card_check.py 由其守卫①处理，
  # 这里同样直接 complete，与判定器 skip(2) 语义一致）
  if [[ "${SKIP_PRODUCE_CHECK:-0}" == "1" || -n "$no_check" ]]; then
    [[ -n "$no_check" ]] && warn "无快照基准线，按任务卡约定本次不做产出校验，直接收尾"
    "$WF_HERMES" kanban --board "$BOARD" complete "$task_id" \
      --summary "lane($agent_name) 完成（跳过产出校验）" --result "exit=0" >/dev/null 2>&1 || true
    log "收尾：complete（跳过产出校验）"
    return 0
  fi

  # 三态判定：0 produced / 1 EMPTY / 2 skip / 其他=判定器异常
  # 【硬约束】快照由 card_check.py（Python）统一生成，bash 只原样带回
  # snap_before / snap_after 字符串——曾有实现让 bash 自己算指纹
  # （CRLF/LF 不一致）导致判定恒为"有产出"，守卫从未生效。
  local snap_after verdict_out verdict_rc
  snap_after="$("$PY_BIN" "$CARD_CHECK_PY" snapshot "$project_dir" 2>/dev/null)" || true
  verdict_out="$("$PY_BIN" "$CARD_CHECK_PY" verdict "$project_dir" "$BOARD" "$task_id" "$snap_before" 2>&1)"
  verdict_rc=$?

  case "$verdict_rc" in
    0)  # produced
      "$WF_HERMES" kanban --board "$BOARD" complete "$task_id" \
        --summary "lane($agent_name) 完成" --result "exit=0 produced" >/dev/null 2>&1 || true
      log "收尾：complete（produced：$verdict_out）"
      return 0
      ;;
    1)  # EMPTY：假 done，block + 评论留证
      # 快照对比写进评论，格式 <HEAD>\t<指纹>，供人工复核 git 历史
      "$WF_HERMES" kanban --board "$BOARD" block "$task_id" \
        "⚠️ 产出校验未通过（疑似假 done）：$verdict_out" >/dev/null 2>&1 || true
      "$WF_HERMES" kanban --board "$BOARD" comment "$task_id" \
        "产出校验说明：$verdict_out
派单前快照：$snap_before
收尾时快照：$snap_after" >/dev/null 2>&1 || true
      err "产出校验未通过（EMPTY），卡已 block：$verdict_out"
      return 1
      ;;
    2)  # skip：验证型卡 / 非 git / 显式跳过
      "$WF_HERMES" kanban --board "$BOARD" complete "$task_id" \
        --summary "lane($agent_name) 完成（校验不适用：$verdict_out）" --result "exit=0 skip" >/dev/null 2>&1 || true
      log "收尾：complete（skip：$verdict_out）"
      return 0
      ;;
    *)  # 判定器异常退出：显式降级为 skip，但必须留痕，不许静默 fail-open
      warn "判定器异常退出(exit=$verdict_rc)，本次未做校验：$verdict_out"
      "$WF_HERMES" kanban --board "$BOARD" complete "$task_id" \
        --summary "lane($agent_name) 完成" --result "exit=0 判定器异常未校验" >/dev/null 2>&1 || true
      "$WF_HERMES" kanban --board "$BOARD" comment "$task_id" \
        "判定器异常退出(exit=$verdict_rc)，本次未做校验。派单前快照：$snap_before；收尾时快照：$snap_after" >/dev/null 2>&1 || true
      return 0
      ;;
  esac
}

main "$@"
exit $?
