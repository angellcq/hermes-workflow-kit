#!/usr/bin/env bash
# Hermes Workflow Kit 最小测试集
# 用法：bash tests/run_tests.sh
# 覆盖：脚本语法 / python 编译 / 角色动态加载 / pipeline dry-run / 引用完整性 / update_active 双路径
#
# 兼容性说明：
#   - python 调用一律用相对路径（cd 到仓库根）：避免 Windows Python 收到
#     MSYS 绝对路径（/e/...）时被错误拼接
#   - 临时文件用仓库内 .test-tmp/（已 gitignore）：部分受限环境对 /tmp
#     下 mktemp 目录的清理有拦截，仓库内路径无此问题
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TMPDIR=/tmp
cd "$ROOT"

PASS=0
FAIL=0

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

find_py() {
  if command -v python &>/dev/null; then command -v python
  elif command -v python3 &>/dev/null; then command -v python3
  else echo ""; fi
}
PY=$(find_py)

echo "══ [1/10] shell 语法检查 ══"
for f in scripts/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f") 语法错误"; fi
done

echo "══ [2/10] python 编译检查 ══"
if [[ -z "$PY" ]]; then
  bad "未找到 python，跳过"
else
  for f in scripts/*.py; do
    if "$PY" -m py_compile "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f") 编译失败"; fi
  done
fi

echo "══ [3/10] 角色动态加载冒烟 ══"
ROLES_OUT=$(CLAUDE_AGENTS_DIR="通用角色库" bash scripts/agent-bridge.sh roles 2>/dev/null)
COUNT=$(echo "$ROLES_OUT" | grep -cE '^[a-z][a-z-]+[[:space:]]')
if [[ "$COUNT" -eq 11 ]]; then
  ok "角色库加载 11 个（通用角色库，deprecated/ 不计）"
else
  bad "预期 11 个角色（v5.0 起 5 个 C 级移入 deprecated/），实际 $COUNT"
fi
# 块格式 description 兼容（临时目录构造 description: | 样例）
TD="$ROOT/.test-tmp"; mkdir -p "$TD"
printf -- '---\nname: block-desc-test\ndescription: |\n  块格式描述冒烟\nmodel: sonnet\n---\n' > "$TD/block-desc-test.md"
BDESC=$(CLAUDE_AGENTS_DIR="$TD" bash scripts/agent-bridge.sh roles 2>/dev/null | grep "block-desc-test")
if [[ "$BDESC" == *"块格式描述冒烟"* ]]; then ok "块格式 description 解析"
else bad "块格式 description 解析失败：$BDESC"; fi
rm -f "$TD/block-desc-test.md"; rmdir "$TD" 2>/dev/null

echo "══ [4/10] pipeline dry-run 冒烟 ══"
if [[ -z "$PY" ]]; then
  bad "未找到 python，跳过"
else
  TP="$ROOT/.test-tmp/proj"; mkdir -p "$TP"
  printf '[project]\nname = "smoke-test"\nversion = "0.1.0"\n' > "$TP/pyproject.toml"
  WTP="$TP"
  command -v cygpath &>/dev/null && WTP=$(cygpath -w "$TP")
  if "$PY" scripts/pipeline.py --project my-app --task "冒烟测试" --dry-run --only-analyze --path "$WTP" >/dev/null 2>&1; then
    ok "pipeline --dry-run --only-analyze（--path 临时项目）"
  else
    bad "pipeline dry-run 失败"
  fi
  rm -f "$TP/pyproject.toml"; rmdir "$TP" 2>/dev/null
fi

echo "══ [5/10] 引用完整性 ══"
if [[ -z "$PY" ]]; then
  bad "未找到 python，跳过"
elif "$PY" scripts/check-references.py; then
  :
else
  bad "存在断链/失效引用（见上方输出）"
fi

echo "══ [6/10] update_active 双路径 ══"
TMPJ="$ROOT/.test-tmp/active.json"
TB="$ROOT/.test-tmp/tasks"
mkdir -p "$ROOT/.test-tmp"
rm -f "$TMPJ"
TASK_BASE="$TB" ACTIVE_FILE="$TMPJ" bash -c '
  source scripts/agent-bridge.sh
  update_active t-999 test-role 1234 running
  update_active t-998 other-role 5678 running
  update_active t-999 test-role 1234 done
' 2>/dev/null
if grep -q '"task_id": "t-999"' "$TMPJ" 2>/dev/null \
   && grep -q '"status": "done"' "$TMPJ" 2>/dev/null \
   && [[ $(grep -c '"task_id": "t-999"' "$TMPJ") -eq 1 ]]; then
  ok "active.json 更新（去重+状态迁移）"
else
  bad "active.json 更新异常"
fi
rm -f "$TMPJ"; rmdir "$TB" 2>/dev/null
rmdir "$ROOT/.test-tmp/proj" 2>/dev/null; rmdir "$ROOT/.test-tmp" 2>/dev/null

echo "══ [7/10] pipeline 单元测试（FakeRunner 注入）══"
if [[ -z "$PY" ]]; then
  bad "未找到 python，跳过"
elif "$PY" -m unittest discover -s tests -p "test_*.py" >/dev/null 2>&1; then
  ok "test_pipeline.py 全部通过"
else
  bad "pipeline 单元测试失败（python -m unittest discover -s tests 查看详情）"
fi

echo "══ [8/10] cross-language 清单加载 ══"
# 注意：先捕获输出再 grep -q。`cmd | grep -q` 在输出超过管道缓冲（实测 >64KB/MSYS ~4KB）
# 时 grep 提前退出 → 上游收 SIGPIPE 而"报错"，本用例曾因此误判失败。
LANG_LIST=$(bash scripts/cross-language.sh list 2>/dev/null)
if echo "$LANG_LIST" | grep -q "强类型编译型"; then
  ok "languages.yaml categories 加载"
else
  bad "cross-language list 加载失败"
fi
TP2="$ROOT/.test-tmp/pyproj"; mkdir -p "$TP2"; touch "$TP2/pyproject.toml"
LANG_DETECT=$(bash scripts/cross-language.sh detect "$TP2" 2>/dev/null)
if echo "$LANG_DETECT" | grep -q "pyproject.toml → python"; then
  ok "languages.yaml markers 检测"
else
  bad "cross-language detect 失败"
fi
rm -f "$TP2/pyproject.toml"; rmdir "$TP2" 2>/dev/null; rmdir "$ROOT/.test-tmp" 2>/dev/null

echo "══ [9/10] agent-bridge --json 输出契约 ══"
ROLES_JSON=$(CLAUDE_AGENTS_DIR="通用角色库" bash scripts/agent-bridge.sh roles --json 2>/dev/null)
if echo "$ROLES_JSON" | grep -q '"name": "backend-developer"' && echo "$ROLES_JSON" | grep -q '"description"'; then
  ok "roles --json（11 角色 JSON 数组）"
else
  bad "roles --json 输出异常"
fi
TB2="$ROOT/.test-tmp/tasks"; mkdir -p "$TB2/t-j1"
printf '{"task_id":"t-j1","status":"running"}\n' > "$TB2/t-j1/status.json"
MON_JSON=$(TASK_BASE="$TB2" CLAUDE_AGENTS_DIR="通用角色库" bash scripts/agent-bridge.sh monitor --task-id t-j1 --json 2>/dev/null)
if echo "$MON_JSON" | grep -q '"task_id": "t-j1"'; then
  ok "monitor --json（status.json + log_tail）"
else
  bad "monitor --json 输出异常"
fi
rm -f "$TB2/t-j1/status.json"; rmdir "$TB2/t-j1" 2>/dev/null; rmdir "$TB2" 2>/dev/null; rmdir "$ROOT/.test-tmp" 2>/dev/null

echo "══ [10/10] 派单器六道守卫 + 三态产出校验（T-KIT-P2）══"
# 独立子测试（自建一次性看板 kit-p2-selftest-guards，结束归档清理）。
# 注意：该用例含真实 hermes CLI 调用（单次约 2-4 秒），全量实测约 1-2 分钟，
# 是整个测试集里最慢的一段——放在最后，前面快用例先失败先暴露。
GT_OUT=$(bash tests/test_dispatch_guards.sh 2>&1)
GT_RC=$?
GUARD_PASS=$(echo "$GT_OUT" | sed -n 's/.*═══ 结果：\([0-9]*\) 通过.*/\1/p' | tail -1)
if [[ "$GT_RC" -eq 0 && "${GUARD_PASS:-0}" -ge 15 ]]; then
  ok "守卫 6 分支全过（$GUARD_PASS 断言通过）"
else
  echo "$GT_OUT" | tail -20
  bad "守卫测试失败（rc=$GT_RC，通过断言 $GUARD_PASS 个）"
fi

# ── 容错注册块：独立场景测试脚本逐个注册（T-KIT-P3A §2.4）──
# 别的分支会并行新增测试文件，此处按文件存在性容错：不在就跳过，
# 不硬编码。失败则总退出码非 0。
echo "══ [11/11] 独立场景测试注册块 ══"
for f in tests/test_sentinel.sh tests/test_watchdog_signals.sh tests/test_install_agents.sh tests/test_bootstrap.sh; do
  if [[ ! -f "$f" ]]; then
    echo "  (跳过：$f 不存在)"
    continue
  fi
  SC_OUT=$(bash "$f" 2>&1)
  SC_RC=$?
  SC_PASS=$(echo "$SC_OUT" | sed -n 's/.*═══ 结果：\([0-9]*\) 通过.*/\1/p' | tail -1)
  if [[ "$SC_RC" -eq 0 && "${SC_PASS:-0}" -ge 1 ]]; then
    ok "$(basename "$f")（$SC_PASS 断言通过）"
  else
    echo "$SC_OUT" | tail -20
    bad "$(basename "$f") 失败（rc=$SC_RC，通过断言 ${SC_PASS:-0} 个）"
  fi
done

echo ""
echo "═══ 结果：$PASS 通过 / $FAIL 失败 ═══"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
