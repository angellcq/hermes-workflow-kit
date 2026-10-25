#!/usr/bin/env bash
# deploy-one-project.sh --prune 保护 config/wf.env 回归测试（T-KIT-P12）
# 用法：bash tests/test_deploy_prune.sh
#
# 背景：--prune 遍历名单含 config，而 kit 源的 config/ 只有 wf.env.example，
# 项目本地的 config/wf.env 是机器本地灰度配置，会被当陈旧文件 rm -f 掉
# → 派单器配置消失（哨兵 total_ready 恒 0）。
#
# 断言（P1..P3）：
#   P1  config/wf.env 仍然存在且内容未变（WF_BOARD=fixture）
#   P2  skills/obsolete.txt 已被删（prune 功能没被整体关掉）
#   P3  脚本输出含「保护: config/wf.env」一行
#
# ⚠ SRC 指向 kit 根（工作树根，含 config/ 等 5 个镜像目录）；全用临时目录，不碰真实项目。
# 输出契约：═══ 结果：<N> 通过 ═══（run_tests.sh 容错注册块按此解析）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/hermes-workflow-update/scripts/deploy-one-project.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-prune-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PROJ="$TMP/proj"
mkdir -p "$PROJ/.hermes/config" "$PROJ/.hermes/skills"

# 机器本地灰度配置（源里没有对应文件 → prune 名单会命中它）
printf 'WF_BOARD=fixture\nWF_RUNTIME_MODE=grey\n' > "$PROJ/.hermes/config/wf.env"
# 陈旧文件（源里也没有 → prune 应删）
echo "obsolete" > "$PROJ/.hermes/skills/obsolete.txt"

SRC="$ROOT" bash "$SCRIPT" "$PROJ" --prune > "$TMP/out.log" 2>&1
RC=$?

# P1: wf.env 存活且内容未变
if [[ -f "$PROJ/.hermes/config/wf.env" ]] && grep -q '^WF_BOARD=fixture$' "$PROJ/.hermes/config/wf.env" \
   && grep -q '^WF_RUNTIME_MODE=grey$' "$PROJ/.hermes/config/wf.env"; then
  ok "P1 config/wf.env 存活且内容未变"
else
  bad "P1 config/wf.env 被删或内容被改（rc=$RC）"
fi

# P2: 陈旧文件已被删
if [[ ! -e "$PROJ/.hermes/skills/obsolete.txt" ]]; then
  ok "P2 skills/obsolete.txt 已被 prune 删除"
else
  bad "P2 skills/obsolete.txt 未被删（prune 功能失效）"
fi

# P3: 输出含保护行
if grep -q '保护: config/wf.env' "$TMP/out.log"; then
  ok "P3 输出含「保护: config/wf.env」"
else
  bad "P3 输出缺保护行（实际输出尾部：）"; tail -5 "$TMP/out.log"
fi

[[ "$RC" -eq 0 ]] && ok "脚本退出码 0" || bad "脚本退出码 $RC ≠ 0"

rm -rf "$TMP"
echo "═══ 结果：$PASS 通过 ═══"
[[ "$FAIL" -eq 0 ]]
