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

echo "══ [1/6] shell 语法检查 ══"
for f in scripts/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f") 语法错误"; fi
done

echo "══ [2/6] python 编译检查 ══"
if [[ -z "$PY" ]]; then
  bad "未找到 python，跳过"
else
  for f in scripts/*.py; do
    if "$PY" -m py_compile "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f") 编译失败"; fi
  done
fi

echo "══ [3/6] 角色动态加载冒烟 ══"
ROLES_OUT=$(CLAUDE_AGENTS_DIR="通用角色库" bash scripts/agent-bridge.sh roles 2>/dev/null)
COUNT=$(echo "$ROLES_OUT" | grep -cE '^[a-z][a-z-]+[[:space:]]')
if [[ "$COUNT" -eq 16 ]]; then
  ok "角色库加载 16 个（仓库通用角色库）"
else
  bad "预期 16 个角色，实际 $COUNT"
fi
# 块格式 description 兼容（临时目录构造 description: | 样例）
TD="$ROOT/.test-tmp"; mkdir -p "$TD"
printf -- '---\nname: block-desc-test\ndescription: |\n  块格式描述冒烟\nmodel: sonnet\n---\n' > "$TD/block-desc-test.md"
BDESC=$(CLAUDE_AGENTS_DIR="$TD" bash scripts/agent-bridge.sh roles 2>/dev/null | grep "block-desc-test")
if [[ "$BDESC" == *"块格式描述冒烟"* ]]; then ok "块格式 description 解析"
else bad "块格式 description 解析失败：$BDESC"; fi
rm -f "$TD/block-desc-test.md"; rmdir "$TD" 2>/dev/null

echo "══ [4/6] pipeline dry-run 冒烟 ══"
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

echo "══ [5/6] 引用完整性 ══"
if [[ -z "$PY" ]]; then
  bad "未找到 python，跳过"
elif "$PY" scripts/check-references.py; then
  :
else
  bad "存在断链/失效引用（见上方输出）"
fi

echo "══ [6/6] update_active 双路径 ══"
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

echo ""
echo "═══ 结果：$PASS 通过 / $FAIL 失败 ═══"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
