#!/usr/bin/env bash
# install-claude-agents.sh 场景测试（T-KIT-P4）
# 用法：bash tests/test_install_agents.sh
#
# ⚠ 绝对不许碰真实的 ~/.claude/agents —— 全部用 --dir <临时目录>。
# 6 条断言：
#   I1 --dry-run 不写盘（目标目录仍为空）
#   I2 首次安装数量与源一致（去掉 deprecated/ 子目录）
#   I3 frontmatter name: 与文件名一致（抽样 grep）
#   I4 幂等：第二次 SKIP= 文件数、INSTALL=0
#   I5 --only backend-developer 只装 1 个
#   I6 --prefix wf- 生效（文件名与 name: 都带 wf-）
# 输出契约：═══ 结果：<N> 通过 ═══（run_tests.sh 容错注册块按此解析）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/install-claude-agents.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

 TMPD="$ROOT/.test-tmp/instagents"
rm -rf "$TMPD"; mkdir -p "$TMPD"
TMP=$(cygpath -m "$TMPD" 2>/dev/null || echo "$TMPD")
trap 'rm -rf "$TMPD"' EXIT

# 期望源文件数：通用角色库顶层 .md（find -maxdepth 1 天然排除 deprecated/ 子目录）
EXPECT_N=$(find "$ROOT/通用角色库" -maxdepth 1 -name "*.md" -type f | wc -l)

echo "══ I1 --dry-run 不写盘 ══"
DRY_OUT=$(bash "$SCRIPT" --dry-run --dir "$TMP/i1" 2>&1)
if [[ ! -d "$TMP/i1" ]] && echo "$DRY_OUT" | grep -q "INSTALL=$EXPECT_N"; then
  ok "--dry-run 零写盘且预计 INSTALL=$EXPECT_N"
else
  bad "--dry-run 写了盘或没有预计动作（目录存在：$([[ -d "$TMP/i1" ]] && echo yes || echo no)）"
fi

echo "══ I2 首次安装数量与源一致 ══"
I2_OUT=$(bash "$SCRIPT" --dir "$TMP/i2" 2>&1)
I2_N=$(ls "$TMP/i2"/*.md 2>/dev/null | wc -l)
if [[ "$I2_N" -eq "$EXPECT_N" ]] && echo "$I2_OUT" | grep -q "INSTALL=$EXPECT_N"; then
  ok "装出 $I2_N 个（源 $EXPECT_N 个，跳过 deprecated/）"
else
  bad "装出 $I2_N 个 ≠ 源 $EXPECT_N 个"
fi

echo "══ I3 frontmatter name: 与文件名一致 ══"
if grep -q "^name: cc-backend-developer$" "$TMP/i2/cc-backend-developer.md" 2>/dev/null; then
  ok "cc-backend-developer.md 的 name: 行带前缀且与文件名一致"
else
  bad "name: 与文件名不一致或缺失"
fi
# 反例：devops.md 正文的 name: CI 不许被改
if grep -q "^name: CI" "$TMP/i2/cc-devops.md" 2>/dev/null; then
  ok "正文 name: CI 未被误改"
else
  bad "正文 name: CI 被误改或丢失"
fi

echo "══ I4 幂等：第二次全 SKIP ══"
I4_OUT=$(bash "$SCRIPT" --dir "$TMP/i2" 2>&1)
I4_SKIP=$(echo "$I4_OUT" | sed -n 's/.*SKIP=\([0-9]*\).*/\1/p')
I4_INST=$(echo "$I4_OUT" | sed -n 's/.*INSTALL=\([0-9]*\).*/\1/p')
if [[ "${I4_SKIP:-0}" -eq "$EXPECT_N" && "${I4_INST:-1}" -eq 0 ]]; then
  ok "第二次 INSTALL=0 SKIP=$I4_SKIP（rc=0）"
else
  bad "幂等失败：INSTALL=$I4_INST SKIP=$I4_SKIP（期望 0/$EXPECT_N）"
fi

echo "══ I5 --only backend-developer 只装 1 个 ══"
bash "$SCRIPT" --dir "$TMP/i5" --only backend-developer &>/dev/null
I5_N=$(ls "$TMP/i5" 2>/dev/null | wc -l)
if [[ "$I5_N" -eq 1 && -f "$TMP/i5/cc-backend-developer.md" ]]; then
  ok "--only 精确装 1 个"
else
  bad "--only 装出 $I5_N 个（期望 1）"
fi

echo "══ I6 --prefix wf- 生效 ══"
bash "$SCRIPT" --dir "$TMP/i6" --prefix wf- --only backend-developer &>/dev/null
if [[ -f "$TMP/i6/wf-backend-developer.md" ]] \
   && grep -q "^name: wf-backend-developer$" "$TMP/i6/wf-backend-developer.md" 2>/dev/null; then
  ok "文件名与 name: 都带 wf- 前缀"
else
  bad "--prefix wf- 未生效"
fi

echo ""
echo "═══ 结果：$PASS 通过 ═══"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
