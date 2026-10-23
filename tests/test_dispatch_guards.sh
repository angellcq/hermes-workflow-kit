#!/usr/bin/env bash
# test_dispatch_guards.sh — 派单器六道守卫 + 三态产出校验测试（T-KIT-P2 §2.6）
#
# 用假执行器（claude 替身，记录参数、按场景决定是否 git commit）覆盖 6 个分支，
# 全部断言退出码与看板状态。自建一次性看板（kit-p2-selftest-guards），结束归档清理，
# 不碰 hermes-kit 等正式板的任何卡。
#
# 10 个分支（B1–B6 守卫判定；B7–B10 角色真加载 + 权限模式，T-KIT-P6）：
#   B1 卡已是 running        → 退出码 3，假执行器未被调用（调用记录文件证明）
#   B2 claim 后非 running    → 退出码 3（模拟父卡未完成：用父卡未 done 的子卡）
#   B3 工人产出（假执行器 commit）→ 退出码 0，卡 done，摘要含 produced
#   B4 工人零产出（exit 0 不改文件）→ 退出码 1，卡 blocked，评论含两次快照对比
#   B5 验证型卡零产出（标题含"验收"）→ 退出码 0，卡 done
#   B6 工人 exit=7           → 卡 blocked，脚本退出码 7
#   B7 agents 目录有该角色   → 参数含 --agent 与 --permission-mode acceptEdits
#   B8 agents 目录无该角色   → 参数不含 --agent；日志含「角色加载：跳过」；卡仍 done
#   B9 ENABLE=0（角色文件在）→ 参数不含 --agent
#   B10 PERMISSION_MODE=off  → 参数不含 --permission-mode
#
# ⚠ 路径形态陷阱（实测踩过）：传给**原生程序**（git、假执行器内的 git、
# dispatch-lane.sh 的 project_dir 参数）的路径必须是 C:/... 形式；
# MSYS 的 /c/... 形式原生 git 报 fatal: cannot change to '...'。
# 所以全部经 native_path（scripts/wf_common.py，与被测代码同一实现）
# 转成 Windows 原生形态后才使用。纯 bash 内部路径（mkdir/rm/hermes CLI 不敏感）
# 不受此限制。
#
# ⚠ 运行耗时：约 6 个分支 × 每分支 2-4 次 hermes CLI 调用（单次约 2-4 秒），
# 全量实测约 1-2 分钟。每个分支内 show 只调一次，状态/评论从同一份输出取。
#
# ⚠ stdin 必须关掉（实测踩过）：hermes CLI 在**非 tty** 下遇到需要确认/读取输入的分支会
# 永久等待，整条 run_tests.sh 就挂在这一步（实测挂 > 8 分钟，无任何输出）。由调用方
# 逐个调用点加 `</dev/null` 太容易漏，改为本脚本开头一次性 `exec </dev/null`。
set -uo pipefail
exec </dev/null

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TEST_BOARD="kit-p2-selftest-guards"
TMP="$ROOT/.test-tmp/guards"
CALL_LOG="$TMP/fake-claude.calls"
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

# native pathbridge：MSYS 路径 → 原生形态（优先 cygpath -m；无则用
# scripts/wf_common.py 的 native_path——与被测代码同一个实现，保证一致）
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

# ── 假执行器：记录参数；FAKE_CLAUDE_MODE=commit 时在项目里写新文件再 commit ──
FAKE_CLAUDE="$TMP/fake-claude.sh"
cat > "$FAKE_CLAUDE" <<'FAKEEOF'
#!/usr/bin/env bash
# 假 claude：把调用参数追加到 $FAKE_CLAUDE_CALLS，按 $FAKE_CLAUDE_MODE 行为：
#   none    = exit 0 什么都不改（零产出）
#   commit  = 在 $FAKE_CLAUDE_REPO 写一个新文件并 git commit（真产出）。
#     注意必须先写新文件：只跑 add+commit 时若工作区是干净的就
#     "nothing to commit"，HEAD 不变，产出校验正确判 EMPTY——
#     第一次实测 B3 就因此误败（这不是守卫的错，是替身没产出）。
#   fail7   = exit 7（worker 崩溃）
# FAKE_CLAUDE_REPO 必须已是原生 Windows 形态（C:/...），见文件头路径陷阱说明
set -u
echo "ARGS: $*" >> "${FAKE_CLAUDE_CALLS:?FAKE_CLAUDE_CALLS 未设置}"
case "${FAKE_CLAUDE_MODE:-none}" in
  commit)
    echo "fake worker output $(date +%s%N)" > "${FAKE_CLAUDE_REPO:?}/worker-output.txt"
    git -C "${FAKE_CLAUDE_REPO:?}" add -A
    git -C "${FAKE_CLAUDE_REPO:?}" -c user.name=fake -c user.email=fake@t commit -m "fake worker output" >/dev/null 2>&1
    exit 0 ;;
  fail7) exit 7 ;;
  *)     exit 0 ;;
esac
FAKEEOF
chmod +x "$FAKE_CLAUDE"

# ── 前置环境：一次性看板 + 一次性 git 仓库 ──
setup_env() {
  hermes kanban boards create "$TEST_BOARD" >/dev/null 2>&1 || true
  rm -rf "$TMP/repo"; mkdir -p "$TMP/repo"
  # 传给原生 git 的路径先过 native_of（见文件头路径陷阱）
  REPO_NATIVE="$(native_of "$TMP/repo")"
  git -C "$REPO_NATIVE" init -q
  git -C "$REPO_NATIVE" config user.name test
  git -C "$REPO_NATIVE" config user.email test@t
  echo base > "$TMP/repo/base.txt"
  git -C "$REPO_NATIVE" add -A
  git -C "$REPO_NATIVE" commit -qm base
  export FAKE_CLAUDE_CALLS="$CALL_LOG"
  export FAKE_CLAUDE_REPO="$REPO_NATIVE"
  : > "$CALL_LOG"
}

cleanup_env() {
  # 归档并删除测试板（board rm 是归档式删除，不污染任何正式板）
  hermes kanban boards rm "$TEST_BOARD" >/dev/null 2>&1 || true
  rm -rf "$TMP/repo" "$FAKE_CLAUDE" "$CALL_LOG"
  rmdir "$TMP" 2>/dev/null || true
  rmdir "$ROOT/.test-tmp" 2>/dev/null || true
}
trap cleanup_env EXIT

# 建卡：<标题>；stdout = 卡号
new_card() {
  hermes kanban --board "$TEST_BOARD" create "$1" 2>/dev/null | awk '{print $2}'
}

# 一次 show 拿全量输出，复用给状态与评论断言（耗时优化：show 单次约 2-4 秒）
card_show() {
  hermes kanban --board "$TEST_BOARD" show "$1" 2>/dev/null
}

echo "══ 派单器守卫测试（板：$TEST_BOARD）══"
setup_env

# ── B1：卡已是 running → 退出码 3，假执行器未被调用 ──
echo "── B1 卡已是 running：拒绝双写 ──"
B1=$(new_card "B1 双写守卫")
hermes kanban --board "$TEST_BOARD" claim "$B1" --ttl 7200 >/dev/null 2>&1
: > "$CALL_LOG"
OUT=$(FAKE_CLAUDE_MODE=none CLAUDE_BIN="$FAKE_CLAUDE" WF_BOARD="$TEST_BOARD" WF_REPO="$REPO_NATIVE" WF_PYTHON="$PY" WF_HERMES="$HERMES_BIN" \
  bash scripts/dispatch-lane.sh "$B1" backend-developer "B1 任务" "$REPO_NATIVE" "$TEST_BOARD" 2>&1)
RC=$?
B1_SHOW=$(card_show "$B1")
if [[ "$RC" -eq 3 ]]; then ok "B1 退出码 3（实际 $RC）"; else bad "B1 退出码期望 3，实际 $RC；输出：$OUT"; fi
if [[ ! -s "$CALL_LOG" ]]; then ok "B1 假执行器未被调用（调用记录为空）"; else bad "B1 假执行器被调用了！记录：$(cat "$CALL_LOG")"; fi
if echo "$B1_SHOW" | grep -q "^  status:[[:space:]]*running"; then ok "B1 卡保持 running（不被误收尾）"; else bad "B1 卡状态异常：$(echo "$B1_SHOW" | head -3)"; fi

# ── B2：claim 后非 running（父卡未完成的子卡）→ 退出码 3 ──
echo "── B2 父卡未完成子卡 claim 不动：退出 3 ──"
BP=$(new_card "B2 父卡")
B2=$(hermes kanban --board "$TEST_BOARD" create "B2 子卡" --parent "$BP" 2>/dev/null | awk '/^Created /{print $2}')
OUT=$(FAKE_CLAUDE_MODE=none CLAUDE_BIN="$FAKE_CLAUDE" WF_BOARD="$TEST_BOARD" WF_REPO="$REPO_NATIVE" WF_PYTHON="$PY" WF_HERMES="$HERMES_BIN" \
  bash scripts/dispatch-lane.sh "$B2" backend-developer "B2 任务" "$REPO_NATIVE" "$TEST_BOARD" 2>&1)
RC=$?
B2_SHOW=$(card_show "$B2")
if [[ "$RC" -eq 3 ]]; then ok "B2 退出码 3（实际 $RC）"; else bad "B2 退出码期望 3，实际 $RC；输出：$OUT"; fi
if echo "$B2_SHOW" | grep -q "^  status:[[:space:]]*todo"; then ok "B2 子卡保持 todo（claim 未生效不被硬派）"; else bad "B2 子卡状态异常：$(echo "$B2_SHOW" | head -3)"; fi

# ── B3：工人真产出（假执行器 commit）→ 0，卡 done，摘要含 produced ──
echo "── B3 工人产出：complete done ──"
B3=$(new_card "B3 真产出")
OUT=$(FAKE_CLAUDE_MODE=commit CLAUDE_BIN="$FAKE_CLAUDE" WF_BOARD="$TEST_BOARD" WF_REPO="$REPO_NATIVE" WF_PYTHON="$PY" WF_HERMES="$HERMES_BIN" \
  bash scripts/dispatch-lane.sh "$B3" backend-developer "B3 任务" "$REPO_NATIVE" "$TEST_BOARD" 2>&1)
RC=$?
B3_SHOW=$(card_show "$B3")
if [[ "$RC" -eq 0 ]]; then ok "B3 退出码 0"; else bad "B3 退出码期望 0，实际 $RC；输出：$OUT"; fi
if echo "$B3_SHOW" | grep -q "^  status:[[:space:]]*done"; then ok "B3 卡 done"; else bad "B3 卡状态异常：$(echo "$B3_SHOW" | head -3)"; fi
if echo "$B3_SHOW" | grep -q "produced"; then ok "B3 摘要/评论含 produced"; else bad "B3 摘要缺 produced：$(echo "$B3_SHOW" | head -8)"; fi

# ── B4：工人零产出 → 1，卡 blocked，评论含两次快照对比 ──
echo "── B4 零产出假 done：block + 快照对比 ──"
B4=$(new_card "B4 零产出")
OUT=$(FAKE_CLAUDE_MODE=none CLAUDE_BIN="$FAKE_CLAUDE" WF_BOARD="$TEST_BOARD" WF_REPO="$REPO_NATIVE" WF_PYTHON="$PY" WF_HERMES="$HERMES_BIN" \
  bash scripts/dispatch-lane.sh "$B4" backend-developer "B4 任务" "$REPO_NATIVE" "$TEST_BOARD" 2>&1)
RC=$?
B4_SHOW=$(card_show "$B4")
if [[ "$RC" -eq 1 ]]; then ok "B4 退出码 1（实际 $RC）"; else bad "B4 退出码期望 1，实际 $RC；输出：$OUT"; fi
if echo "$B4_SHOW" | grep -q "^  status:[[:space:]]*blocked"; then ok "B4 卡 blocked"; else bad "B4 卡状态异常：$(echo "$B4_SHOW" | head -3)"; fi
# 两次快照对比：评论里应出现"派单前快照"与"收尾时快照"两行（各含 HEAD\t指纹）
if echo "$B4_SHOW" | grep -q "派单前快照" && echo "$B4_SHOW" | grep -q "收尾时快照"; then
  ok "B4 评论含两次快照对比"
else
  bad "B4 评论缺快照对比：$(echo "$B4_SHOW" | grep -A3 Comments || echo '(无评论段)')"
fi
if echo "$B4_SHOW" | grep -q "疑似假 done"; then ok "B4 评论含假 done 警示"; else bad "B4 评论缺假 done 警示"; fi

# ── B5：验证型卡零产出（标题含"验收"）→ 0，卡 done ──
echo "── B5 验证型卡零产出：skip 收尾 done ──"
B5=$(new_card "B5 验收类卡（验证型零产出放行）")
OUT=$(FAKE_CLAUDE_MODE=none CLAUDE_BIN="$FAKE_CLAUDE" WF_BOARD="$TEST_BOARD" WF_REPO="$REPO_NATIVE" WF_PYTHON="$PY" WF_HERMES="$HERMES_BIN" \
  bash scripts/dispatch-lane.sh "$B5" backend-developer "B5 任务" "$REPO_NATIVE" "$TEST_BOARD" 2>&1)
RC=$?
B5_SHOW=$(card_show "$B5")
if [[ "$RC" -eq 0 ]]; then ok "B5 退出码 0"; else bad "B5 退出码期望 0，实际 $RC；输出：$OUT"; fi
if echo "$B5_SHOW" | grep -q "^  status:[[:space:]]*done"; then ok "B5 卡 done（验证型 skip 放行）"; else bad "B5 卡状态异常：$(echo "$B5_SHOW" | head -3)"; fi

# ── B6：工人 exit=7 → 卡 blocked，脚本退出码 7 ──
echo "── B6 worker 崩溃：透传退出码 + block ──"
B6=$(new_card "B6 worker 失败")
OUT=$(FAKE_CLAUDE_MODE=fail7 CLAUDE_BIN="$FAKE_CLAUDE" WF_BOARD="$TEST_BOARD" WF_REPO="$REPO_NATIVE" WF_PYTHON="$PY" WF_HERMES="$HERMES_BIN" \
  bash scripts/dispatch-lane.sh "$B6" backend-developer "B6 任务" "$REPO_NATIVE" "$TEST_BOARD" 2>&1)
RC=$?
B6_SHOW=$(card_show "$B6")
if [[ "$RC" -eq 7 ]]; then ok "B6 退出码 7 透传（实际 $RC）"; else bad "B6 退出码期望 7，实际 $RC；输出：$OUT"; fi
if echo "$B6_SHOW" | grep -q "^  status:[[:space:]]*blocked"; then ok "B6 卡 blocked"; else bad "B6 卡状态异常：$(echo "$B6_SHOW" | head -3)"; fi
if echo "$B6_SHOW" | grep -q "失败 exit=7"; then ok "B6 block 原因含 exit=7"; else bad "B6 block 原因缺 exit=7"; fi

# ── T-KIT-P6：角色真加载 + 权限模式（B7–B10）──
# 与宿主机 ~/.claude/agents 状态无关：一律显式 WF_CLAUDE_AGENTS_DIR 指向
# 自建临时目录。假执行器把收到的参数照抄进调用记录，直接断言参数文本。
if [[ -z "$PY" ]]; then
  echo "── B7-B10 跳过：找不到 python（native_of 需要）──"
else
echo "── B7 角色存在：--agent + --permission-mode acceptEdits ──"
AGENTS_DIR="$TMP/agents"; mkdir -p "$AGENTS_DIR"
echo "placeholder" > "$AGENTS_DIR/cc-fake-role.md"
B7=$(new_card "B7 角色真加载")
: > "$CALL_LOG"
OUT=$(FAKE_CLAUDE_MODE=commit CLAUDE_BIN="$FAKE_CLAUDE" WF_BOARD="$TEST_BOARD" WF_REPO="$REPO_NATIVE" WF_PYTHON="$PY" WF_HERMES="$HERMES_BIN" \
  WF_CLAUDE_AGENTS_DIR="$AGENTS_DIR" \
  bash scripts/dispatch-lane.sh "$B7" fake-role "B7 任务" "$REPO_NATIVE" "$TEST_BOARD" 2>&1)
RC=$?
if grep -q -- "--agent cc-fake-role" "$CALL_LOG"; then ok "B7 参数含 --agent cc-fake-role"; else bad "B7 参数缺 --agent cc-fake-role：$(cat "$CALL_LOG")"; fi
if grep -q -- "--permission-mode acceptEdits" "$CALL_LOG"; then ok "B7 参数含 --permission-mode acceptEdits"; else bad "B7 参数缺 --permission-mode acceptEdits"; fi
if grep -q "角色加载：--agent cc-fake-role" <<<"$OUT"; then ok "B7 日志提示 --agent cc-fake-role"; else bad "B7 日志缺 --agent 提示：$OUT"; fi
if [[ "$RC" -eq 0 ]]; then ok "B7 退出码 0（真产出正常收尾）"; else bad "B7 退出码期望 0，实际 $RC；输出：$OUT"; fi

echo "── B8 角色文件不存在：不传 --agent，留痕，卡仍收尾 ──"
AGENTS_EMPTY="$TMP/agents-empty"; mkdir -p "$AGENTS_EMPTY"
B8=$(new_card "B8 角色缺失")
: > "$CALL_LOG"
OUT=$(FAKE_CLAUDE_MODE=commit CLAUDE_BIN="$FAKE_CLAUDE" WF_BOARD="$TEST_BOARD" WF_REPO="$REPO_NATIVE" WF_PYTHON="$PY" WF_HERMES="$HERMES_BIN" \
  WF_CLAUDE_AGENTS_DIR="$AGENTS_EMPTY" \
  bash scripts/dispatch-lane.sh "$B8" backend-developer "B8 任务" "$REPO_NATIVE" "$TEST_BOARD" 2>&1)
RC=$?
if grep -- "--agent" "$CALL_LOG" >/dev/null 2>&1; then bad "B8 不应传 --agent：$(cat "$CALL_LOG")"; else ok "B8 不传 --agent"; fi
if grep -q "角色加载：跳过" <<<"$OUT"; then ok "B8 日志含「角色加载：跳过」"; else bad "B8 日志缺跳过说明：$OUT"; fi
B8_SHOW=$(card_show "$B8")
if [[ "$RC" -eq 0 ]] && echo "$B8_SHOW" | grep -q "^  status:[[:space:]]*done"; then
  ok "B8 卡正常 done（不因缺角色 block）"
else
  bad "B8 卡收尾异常：rc=$RC，状态 $(echo "$B8_SHOW" | grep '^  status:' || echo '?')"
fi

echo "── B9 ENABLE=0：角色文件在也不传 --agent ──"
B9=$(new_card "B9 强制关闭")
: > "$CALL_LOG"
OUT=$(FAKE_CLAUDE_MODE=commit CLAUDE_BIN="$FAKE_CLAUDE" WF_BOARD="$TEST_BOARD" WF_REPO="$REPO_NATIVE" WF_PYTHON="$PY" WF_HERMES="$HERMES_BIN" \
  WF_CLAUDE_AGENTS_DIR="$AGENTS_DIR" WF_CLAUDE_AGENT_ENABLE=0 \
  bash scripts/dispatch-lane.sh "$B9" fake-role "B9 任务" "$REPO_NATIVE" "$TEST_BOARD" 2>&1)
RC=$?
if grep -- "--agent" "$CALL_LOG" >/dev/null 2>&1; then bad "B9 不应传 --agent：$(cat "$CALL_LOG")"; else ok "B9 不传 --agent"; fi
if grep -q "角色加载：关闭（WF_CLAUDE_AGENT_ENABLE=0）" <<<"$OUT"; then ok "B9 日志含关闭说明"; else bad "B9 日志缺关闭说明：$OUT"; fi
if [[ "$RC" -eq 0 ]]; then ok "B9 退出码 0"; else bad "B9 退出码期望 0，实际 $RC；输出：$OUT"; fi

echo "── B10 PERMISSION_MODE=off：不传 --permission-mode ──"
B10=$(new_card "B10 权限模式关闭")
: > "$CALL_LOG"
OUT=$(FAKE_CLAUDE_MODE=commit CLAUDE_BIN="$FAKE_CLAUDE" WF_BOARD="$TEST_BOARD" WF_REPO="$REPO_NATIVE" WF_PYTHON="$PY" WF_HERMES="$HERMES_BIN" \
  WF_CLAUDE_AGENTS_DIR="$AGENTS_DIR" WF_CLAUDE_PERMISSION_MODE=off \
  bash scripts/dispatch-lane.sh "$B10" fake-role "B10 任务" "$REPO_NATIVE" "$TEST_BOARD" 2>&1)
RC=$?
if grep -- "--permission-mode" "$CALL_LOG" >/dev/null 2>&1; then bad "B10 不应传 --permission-mode：$(cat "$CALL_LOG")"; else ok "B10 不传 --permission-mode"; fi
if [[ "$RC" -eq 0 ]]; then ok "B10 退出码 0"; else bad "B10 退出码期望 0，实际 $RC；输出：$OUT"; fi
fi

echo ""
echo "═══ 结果：$PASS 通过 / $FAIL 失败 ═══"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
