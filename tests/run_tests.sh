#!/usr/bin/env bash
# Hermes Workflow Kit 最小测试集
# 用法：bash tests/run_tests.sh
#
# 覆盖：shell 语法 / python 编译 / 角色动态加载 / pipeline dry-run / 引用完整性 /
#       update_active 双路径与空 PID 回归 / python 单元测试（pipeline + scope-check）/
#       cross-language 清单加载 / agent-bridge --json 契约 / scope-check CLI 契约 /
#       preflight 派发前闸门契约
#
# 兼容性与写法约定（踩过的坑）：
#   - python 调用一律用相对路径（cd 到仓库根）：避免 Windows Python 收到
#     MSYS 绝对路径（/e/...）时被错误拼接
#   - 临时文件用仓库内 .test-tmp/（已 gitignore）：部分受限环境对 /tmp
#     下 mktemp 目录的清理有拦截，仓库内路径无此问题
#   - **禁止在对长输出的管道里用 `grep -q`**：命中即关闭管道会让上游脚本吃
#     SIGPIPE，在 pipefail 下管道退出码为 141 → 表现为"功能正常、测试报失败"的假失败。
#     一律用 `grep <pattern> >/dev/null` 或先取到变量再判断
#   - 段号由 seg() 动态生成，不再手写 [n/N]（手工维护分母必然漂移）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TMPDIR=/tmp
cd "$ROOT"

PASS=0
FAIL=0
SEG=0

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
seg() { SEG=$((SEG + 1)); echo "══ [$SEG] $* ══"; }

find_py() {
  if command -v python &>/dev/null; then command -v python
  elif command -v python3 &>/dev/null; then command -v python3
  else echo ""; fi
}
PY=$(find_py)

seg "shell 语法检查"
for f in scripts/*.sh tests/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f") 语法错误"; fi
done

seg "python 编译检查"
if [[ -z "$PY" ]]; then
  bad "未找到 python，跳过"
else
  for f in scripts/*.py tests/*.py; do
    if "$PY" -m py_compile "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f") 编译失败"; fi
  done
fi

seg "角色动态加载冒烟"
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

seg "pipeline dry-run 冒烟"
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

seg "引用完整性"
if [[ -z "$PY" ]]; then
  bad "未找到 python，跳过"
elif "$PY" scripts/check-references.py; then
  :
else
  bad "存在断链/失效引用（见上方输出）"
fi

seg "update_active 双路径 + 空 PID 回归"
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
# 空 pid 回归：cmd_kill 遇到空/非数字 pid 必须只更新状态，不得抛异常、不得丢状态
KT="$ROOT/.test-tmp/killtest/t-empty"
mkdir -p "$KT"
printf '{"task_id":"t-empty","status":"running"}\n' > "$KT/status.json"
: > "$KT/pid"
KT_JSON="$ROOT/.test-tmp/active-kill.json"
rm -f "$KT_JSON"
if TASK_BASE="$ROOT/.test-tmp/killtest" ACTIVE_FILE="$KT_JSON" \
   bash -c 'source scripts/agent-bridge.sh; cmd_kill --task-id t-empty' 2>"$ROOT/.test-tmp/kill.err"; then
  if grep -q '"pid": 0' "$KT_JSON" 2>/dev/null \
     && grep -q '"status": "killed"' "$KT_JSON" 2>/dev/null; then
    ok "空 PID 终止（状态落盘、pid 归零）"
  else
    bad "空 PID 终止后 active.json 未正确更新"
  fi
else
  bad "空 PID 终止命令返回非零（回归失败）"
fi
if grep -q "Traceback" "$ROOT/.test-tmp/kill.err" 2>/dev/null; then
  bad "空 PID 终止抛异常（Traceback 见 .test-tmp/kill.err）"
else
  ok "空 PID 终止无异常输出"
fi
rm -f "$TMPJ" "$KT_JSON" "$ROOT/.test-tmp/kill.err"
rm -rf "$ROOT/.test-tmp/killtest"
rmdir "$TB" 2>/dev/null
rmdir "$ROOT/.test-tmp/proj" 2>/dev/null; rmdir "$ROOT/.test-tmp" 2>/dev/null

seg "python 单元测试（pipeline + scope-check）"
if [[ -z "$PY" ]]; then
  bad "未找到 python，跳过"
elif "$PY" -m unittest discover -s tests -p "test_*.py" >/dev/null 2>&1; then
  ok "tests/test_*.py 全部通过"
else
  bad "单元测试失败（python -m unittest discover -s tests 查看详情）"
fi

seg "cross-language 清单加载"
# 注意：用 grep（不加 -q）。grep -q 命中即关管道 → 脚本吃 SIGPIPE → 141 假失败
if bash scripts/cross-language.sh list 2>/dev/null | grep "强类型编译型" >/dev/null; then
  ok "languages.yaml categories 加载"
else
  bad "cross-language list 加载失败"
fi
TP2="$ROOT/.test-tmp/pyproj"; mkdir -p "$TP2"; touch "$TP2/pyproject.toml"
if bash scripts/cross-language.sh detect "$TP2" 2>/dev/null | grep "pyproject.toml → python" >/dev/null; then
  ok "languages.yaml markers 检测"
else
  bad "cross-language detect 失败"
fi
rm -f "$TP2/pyproject.toml"; rmdir "$TP2" 2>/dev/null; rmdir "$ROOT/.test-tmp" 2>/dev/null

seg "agent-bridge --json 输出契约"
ROLES_JSON=$(CLAUDE_AGENTS_DIR="通用角色库" bash scripts/agent-bridge.sh roles --json 2>/dev/null)
if echo "$ROLES_JSON" | grep '"name": "backend-developer"' >/dev/null \
   && echo "$ROLES_JSON" | grep '"description"' >/dev/null; then
  ok "roles --json（16 角色 JSON 数组）"
else
  bad "roles --json 输出异常"
fi
TB2="$ROOT/.test-tmp/tasks"; mkdir -p "$TB2/t-j1"
printf '{"task_id":"t-j1","status":"running"}\n' > "$TB2/t-j1/status.json"
MON_JSON=$(TASK_BASE="$TB2" CLAUDE_AGENTS_DIR="通用角色库" bash scripts/agent-bridge.sh monitor --task-id t-j1 --json 2>/dev/null)
if echo "$MON_JSON" | grep '"task_id": "t-j1"' >/dev/null; then
  ok "monitor --json（status.json + log_tail）"
else
  bad "monitor --json 输出异常"
fi
rm -f "$TB2/t-j1/status.json"; rmdir "$TB2/t-j1" 2>/dev/null; rmdir "$TB2" 2>/dev/null; rmdir "$ROOT/.test-tmp" 2>/dev/null

seg "scope-check CLI 契约（S4 边界互斥闸门）"
if [[ -z "$PY" ]]; then
  bad "未找到 python，跳过"
else
  # 路径一律相对（cd 到仓库根后使用）：Windows python 不认 MSYS 绝对路径 /d/...
  SCD=".test-tmp/scope"; mkdir -p "$SCD"
  printf 'tasks:\n  - id: t-1\n    task: "a"\n    files_scope:\n      - src/a/\n  - id: t-2\n    task: "b"\n    files_scope:\n      - src/a/x.py\n' > "$SCD/overlap.yaml"
  printf 'tasks:\n  - id: t-1\n    task: "a"\n    files_scope:\n      - src/a/\n  - id: t-2\n    task: "b"\n    files_scope:\n      - src/b/\n' > "$SCD/clean.yaml"
  "$PY" scripts/scope-check.py --tasks "$SCD/overlap.yaml" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 1 ]]; then ok "重叠 → exit 1（禁止并行派发）"
  else bad "重叠时退出码应为 1，实际 $rc"; fi
  "$PY" scripts/scope-check.py --tasks "$SCD/clean.yaml" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 0 ]]; then ok "无重叠 → exit 0（可并行）"
  else bad "无重叠任务退出码应为 0，实际 $rc"; fi
  if "$PY" scripts/scope-check.py --json-input - --json <<< '[{"id":"T-1","goal":"g","files_scope":["src/"]}]' 2>/dev/null | grep '"fingerprints"' >/dev/null; then
    ok "--json 输出含语义指纹（kanban --idempotency-key 用）"
  else
    bad "--json 输出缺少语义指纹"
  fi
  rm -rf "$SCD"; rmdir "$ROOT/.test-tmp" 2>/dev/null
fi

seg "preflight 派发前闸门契约"
PF_OUT=$(bash scripts/preflight.sh --json 2>/dev/null)
if echo "$PF_OUT" | grep '"verdict"' >/dev/null; then
  verdict=$(printf '%s' "$PF_OUT" | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["verdict"])' 2>/dev/null)
  case "$verdict" in
    READY|DEGRADED|NOT_READY) ok "preflight --json verdict=$verdict" ;;
    *) bad "preflight verdict 非法：$verdict" ;;
  esac
  bash scripts/preflight.sh --quiet >/dev/null 2>&1
  rc=$?
  case "$verdict:$rc" in
    READY:0|DEGRADED:1|NOT_READY:2) ok "退出码与 verdict 一致（$rc）" ;;
    *) bad "退出码与 verdict 不一致：verdict=$verdict rc=$rc" ;;
  esac
else
  bad "preflight --json 输出不可解析"
fi

seg "kanban-dispatch 建卡契约（三闸门 → 原生卡）"
if [[ -z "$PY" ]]; then
  bad "未找到 python，跳过"
else
  DD=".test-tmp/dispatch"; mkdir -p "$DD"
  printf 'tasks:
  - id: T-1
    task: "a"
    files_scope:
      - src/a/
' > "$DD/one.yaml"
  printf 'tasks:
  - id: T-1
    task: "a"
    files_scope:
      - src/a/
  - id: T-2
    task: "b"
    files_scope:
      - src/a/b.ts
' > "$DD/clash.yaml"
  D_OUT=$("$PY" scripts/kanban-dispatch.py --tasks "$DD/one.yaml" --dry-run --skip-preflight --json 2>/dev/null)
  if echo "$D_OUT" | grep '"fingerprint"' >/dev/null && echo "$D_OUT" | grep '"preview"' >/dev/null; then
    ok "dry-run：语义指纹 + 预览（不落板）"
  else
    bad "kanban-dispatch dry-run 输出异常"
  fi
  if echo "$D_OUT" | "$PY" -c 'import sys,json;d=json.load(sys.stdin);sys.exit(0 if d["tasks"][0]["cmd"][-3:] and "--idempotency-key" in d["tasks"][0]["cmd"] else 1)' 2>/dev/null; then
    ok "建卡命令含 --idempotency-key（幂等键=指纹）"
  else
    bad "建卡命令缺少幂等键"
  fi
  "$PY" scripts/kanban-dispatch.py --tasks "$DD/clash.yaml" --dry-run --skip-preflight >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 1 ]]; then ok "边界冲突 → exit 1（不建任何卡）"
  else bad "边界冲突时退出码应为 1，实际 $rc"; fi
  rm -rf "$DD"; rmdir "$ROOT/.test-tmp" 2>/dev/null
fi

echo ""
echo "═══ 结果：$PASS 通过 / $FAIL 失败（共 $SEG 段）═══"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
