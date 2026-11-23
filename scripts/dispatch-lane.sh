#!/usr/bin/env bash
# dispatch-lane.sh — 派单器：守卫硬实现 + 三态产出校验（T-KIT-P2）
#
# 用法:
#   bash dispatch-lane.sh <task_id> <agent_or_role> "<prompt>" [project_dir] [board]
#
# 双车道（assignee 前缀即车道，v5.0-P11）:
#   cc-<角色>  → claude 车道（后端业务代码 / WinForm 业务逻辑 / SQL），可 --agent 真加载角色
#   cx-<角色>  → codex 车道（前端域：HTML/CSS/JS、Vue 脚本、WinForm *.Designer.cs 布局）
#   两条车道共用守卫①~⑥、TASK.md、三态产出校验（git 快照对比）与 claim/block/complete 回写；
#   差别只有执行器与角色机制（codex 无 --agent，角色只以文本进 TASK.md）。
#   为什么用前缀而不是新增看板字段：哨兵靠 assignee 前缀过滤，前缀是唯一的防抢单机制
#   （真 profile 名会被网关 dispatcher 认领），加字段还要改 list --json 解析与既有卡。
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
# 本脚本把 1)、2) 从文字规则变成代码。3) 由 P4+P6 闭环：P4 装角色到
# ~/.claude/agents/cc-*.md，P6 本脚本按判定顺序真传 --agent（存在才传）+ 权限模式。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ════════════════════════════════════════════════════════════════
# 配置加载（wf.env 缺省键位 → 环境变量覆盖）
# ════════════════════════════════════════════════════════════════

WF_ENV_FILE="${WF_ENV_FILE:-$SCRIPT_DIR/../config/wf.env}"
# shellcheck disable=SC1090
[[ -f "$WF_ENV_FILE" ]] && . "$WF_ENV_FILE"

WF_BOARD="${WF_BOARD:-}"
# 车道前缀（逗号分隔）。cc- → claude 车道，cx- → codex 车道。
# 哨兵只派带这些前缀的卡，本脚本按前缀分派执行器——前缀即车道。
WF_AGENT_PREFIX="${WF_AGENT_PREFIX:-cc-,cx-}"
WF_CLAUDE_ARGS="${WF_CLAUDE_ARGS:---allowedTools Bash,Read,Write,Edit,MultiEdit,Grep,Glob}"
WF_MAX_OUTPUT_TOKENS="${WF_MAX_OUTPUT_TOKENS:-32000}"
WF_PYTHON="${WF_PYTHON:-}"
WF_HERMES="${WF_HERMES:-hermes}"
# claude 可执行可注入（tests/test_dispatch_guards.sh 用假执行器替身）
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
# codex 车道（cx-*）执行器。沙箱使用 workspace-write：允许改文件并跑构建
# （前端卡常需 npm/dotnet build），但不放开到 danger-full-access——守卫⑥靠 git
# 快照判定产出，越界改盘外文件无从复核。codex exec 在非 tty 下不弹审批，
# 该沙箱就是实际权限边界。CODEX_BIN 可注入（测试用替身，实测 tester 见 tests/）。
CODEX_BIN="${CODEX_BIN:-codex}"
WF_CODEX_SANDBOX="${WF_CODEX_SANDBOX:-workspace-write}"
# P6：角色真加载与权限模式。ENABLE=0 强制关闭 --agent；agents 目录可覆盖
# （该路径只被 bash [[ -f ]] 判断用，不传给原生程序，MSYS 形式即可）；
# 权限模式缺省 acceptEdits，值 off 不传（历史实测缺它时 worker 在权限墙上等/被拒，
# 表现为 exit=0 但零产出的假成功）。
WF_CLAUDE_AGENT_ENABLE="${WF_CLAUDE_AGENT_ENABLE:-1}"
WF_CLAUDE_AGENTS_DIR="${WF_CLAUDE_AGENTS_DIR:-$HOME/.claude/agents}"
WF_CLAUDE_PERMISSION_MODE="${WF_CLAUDE_PERMISSION_MODE:-acceptEdits}"

log()  { echo "[$(date +%H:%M:%S)] $*" >&2; }
warn() { echo "[$(date +%H:%M:%S)] ⚠ $*" >&2; }
err()  { echo "[$(date +%H:%M:%S)] ✗ $*" >&2; }

usage() {
  cat >&2 <<'EOF'
用法: bash dispatch-lane.sh <task_id> <agent_or_role> "<prompt>" [project_dir] [board]

  <task_id>       看板卡号（hermes kanban 卡 id，如 t_xxxx）
  <agent_or_role> 工人角色名：cc-* 走 claude 车道，cx-* 走 codex 车道；
                  不带前缀（如 backend-developer）自动补默认前缀（cc-）
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

  # ---- 工人名规范化 + 车道判定（前缀即车道）----
  # 兼容传 backend-developer（D1 裁决：assignee=路由键，前缀是防抢单机制——
  # 真 profile 名会被网关 dispatcher 抢单）。
  # 车道判定用内置前缀，不依赖 wf.env 的 WF_AGENT_PREFIX：cx- 恒为 codex 车道，
  # 其余（cc- 或自定义前缀）走 claude 车道；裸角色名补默认前缀（历史行为）。
  local agent_name="$agent_in" lane="" default_prefix="${WF_AGENT_PREFIX%%,*}"
  case "$agent_name" in
    cx-*) lane="codex" ;;
    cc-*) lane="claude" ;;
    *)
      lane="claude"
      case "$default_prefix" in
        ""|cx-) default_prefix="cc-" ;;
      esac
      agent_name="${default_prefix}${agent_name}"
      ;;
  esac

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
  # 车道行是 codex 车道唯一能携带的系统约束（codex 无 --agent 机制），必须写进卡。
  local lane_hint
  if [[ "$lane" == "codex" ]]; then
    lane_hint="前端域（HTML/CSS/JS、Vue 前端脚本、WinForm *.Designer.cs 布局与 *.resx）。业务逻辑/服务端代码不在此车道：发现需要改业务代码或控件名，停下来在卡上说明并 block。"
  else
    lane_hint="业务代码域（后端服务、WinForm *Form.cs 业务逻辑、SQL）。不要改 *.Designer.cs、*.resx 与页面标记/样式（那是 cx- 前端车道）。"
  fi
  local tmpdir task_md
  tmpdir="$(mktemp -d)"
  task_md="$tmpdir/TASK.md"
  cat > "$task_md" <<EOF
# 任务

$prompt

## 角色
$agent_name

## 车道
$lane —— $lane_hint

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

  # ═══ 角色真加载判定（P6）：存在才传 --agent，不存在/为空/关闭都留痕 ═══
  # claude 对不存在的 --agent 会直接报错退出（比"没加载角色"更糟），所以
  # 文件存在性是硬前置。判定顺序固定：关闭 → assignee 为空 → 存在 → 跳过。
  local agent_flag=()
  if [[ "$lane" != "claude" ]]; then
    log "角色加载：跳过（$lane 车道无 --agent 机制，角色以「## 角色」文本写进 TASK.md）"
  elif [[ "$WF_CLAUDE_AGENT_ENABLE" == "0" ]]; then
    log "角色加载：关闭（WF_CLAUDE_AGENT_ENABLE=0）"
  elif [[ -z "$agent_name" ]]; then
    log "角色加载：跳过（卡上没有 assignee）"
  elif [[ -f "$WF_CLAUDE_AGENTS_DIR/$agent_name.md" ]]; then
    agent_flag=(--agent "$agent_name")
    log "角色加载：--agent $agent_name"
  else
    log "角色加载：跳过（$WF_CLAUDE_AGENTS_DIR/$agent_name.md 不存在，请先跑 scripts/install-claude-agents.sh）"
  fi

  # 权限模式（P6）：缺省 acceptEdits，off 不传；位置必须在 --output-format json 之前
  local perm_flag=()
  if [[ "$WF_CLAUDE_PERMISSION_MODE" != "off" && -n "$WF_CLAUDE_PERMISSION_MODE" ]]; then
    perm_flag=(--permission-mode "$WF_CLAUDE_PERMISSION_MODE")
  fi

  local worker_rc=0
  if [[ "$lane" == "codex" ]]; then
    # ── codex 车道（前端域）──
    # 用 stdin 喂 TASK.md（`-` 表示从 stdin 读指令）：卡正文常超过内联命令行
    # 安全长度，且引号/换行在参数里会失真。模型不传（用用户自己的 codex 配置）。
    # -C 必须原生形态：codex 是原生 Rust 程序，不认 git-bash 的 /f/... 路径。
    if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
      err "找不到 codex（CODEX_BIN=$CODEX_BIN）：cx- 车道不可用，拒绝派单"
      rm -rf "$tmpdir"
      "$WF_HERMES" kanban --board "$BOARD" block "$task_id" \
        "cx 车道缺少 codex 可执行（CODEX_BIN=$CODEX_BIN）" >/dev/null 2>&1 || true
      return 2
    fi
    local codex_dir
    codex_dir="$(py_native_path "$project_dir")"
    # Windows 沙箱硬约束（codex-cli 0.171.0 实测，2026-11-23）：workspace-write 的默认
    # 可写根集是 [workdir, /tmp, $TMPDIR] 三个，而 Windows 非提权 restricted-token 沙箱
    # 无法执行"split writable root sets"，exec_command 一律报
    #   UnsupportedOperation("windows unelevated restricted-token sandbox cannot
    #   enforce split writable root sets directly; refusing to run unsandboxed")
    # → 工人连 git status 都跑不了、apply_patch 之外的能力全废，只会空转到超时。
    # 收成单根（只剩 workdir，不含 /tmp 与 $TMPDIR）后 exec 恢复正常，且隔离更紧：
    # 写入被锁在项目目录内，派单器守卫⑥的 git 快照判定依旧成立。
    local codex_extra=()
    if [[ "$WF_CODEX_SANDBOX" == "workspace-write" ]]; then
      codex_extra=(-c sandbox_workspace_write.exclude_slash_tmp=true
                   -c sandbox_workspace_write.exclude_tmpdir_env_var=true)
    fi
    log "派单 [task=$task_id lane=codex agent=$agent_name board=$BOARD workdir=$project_dir sandbox=$WF_CODEX_SANDBOX]"
    "$CODEX_BIN" exec -s "$WF_CODEX_SANDBOX" "${codex_extra[@]}" -C "$codex_dir" - < "$task_md"
    worker_rc=$?
  else
    log "派单 [task=$task_id lane=claude agent=$agent_name board=$BOARD workdir=$project_dir]"
    "$CLAUDE_BIN" -p "读 $task_md 并执行。完成后输出修改文件清单与 diff 摘要。" \
      $WF_CLAUDE_ARGS \
      "${agent_flag[@]}" "${perm_flag[@]}" \
      --output-format json
    worker_rc=$?
  fi

  rm -rf "$tmpdir"

  # ═══ 守卫⑥：三态产出校验收尾 ═══
  # worker（claude / codex）底层退出码 ≠ 0：没跑完，不存在"校验产出"，直接 block 并透传。
  # 挡"worker 崩了但脚本当成成功收尾"。
  if [[ "$worker_rc" -ne 0 ]]; then
    "$WF_HERMES" kanban --board "$BOARD" block "$task_id" \
      "lane($agent_name) 失败 exit=$worker_rc，详见 worker 日志" >/dev/null 2>&1 || true
    # claim 释放（best-effort）：block 只改状态不摘 claim_lock，锁挂着的话
    # 下轮哨兵命中"已 claim"静默跳过——盲区（T-KIT-P3A bug2）。实测 block
    # 后 reclaim 不会把卡顶回 ready，熔断语义保得住。
    "$WF_HERMES" kanban --board "$BOARD" reclaim "$task_id" >/dev/null 2>&1 || true
    log "worker 失败（exit=$worker_rc），卡已 block，已尝试释放 claim"
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
      # claim 释放（best-effort）：同上，防 claim_lock 挂着堵住哨兵下轮判定；
      # 实测 block 后 reclaim 不回摆 ready，block 语义保得住（T-KIT-P3A bug2）。
      "$WF_HERMES" kanban --board "$BOARD" reclaim "$task_id" >/dev/null 2>&1 || true
      "$WF_HERMES" kanban --board "$BOARD" comment "$task_id" \
        "产出校验说明：$verdict_out
派单前快照：$snap_before
收尾时快照：$snap_after" >/dev/null 2>&1 || true
      err "产出校验未通过（EMPTY），卡已 block，已尝试释放 claim：$verdict_out"
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
