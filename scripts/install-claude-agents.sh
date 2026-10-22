#!/usr/bin/env bash
# Hermes Workflow Kit — 把通用角色库装成 Claude Code subagent（T-KIT-P4）
#
# 方向纠正：角色是 Claude Code 的 subagent 定义，不是 Hermes profile。
# 历史上的 sync-roles-to-profiles.sh 把角色装成 profile 会让 kanban 的
# profile_exists 闸门对这些名字变真，网关 dispatcher 抢单会把卡 spawn 成
# Hermes worker。本脚本装到 ~/.claude/agents/<prefix><name>.md，
# 用 `claude --agent <prefix><name>` 原生加载。
#
# ⚠ 加载方式铁律：唯一可行是 `claude -p --agent <name>`。由 Agent 工具调用的
#   CC 子 agent 写文件会被权限弹窗卡死（default/bypassPermissions/dontAsk/auto
#   四种模式实测全失败）。本脚本与相关文档都不得指示「用 Agent 工具派发」。
#
# 用法：
#   bash scripts/install-claude-agents.sh [--dry-run] [--dir <目标目录>] [--prefix <前缀>] [--only a,b,c]
#
#   --dir     目标目录（默认 ~/.claude/agents）
#   --prefix  文件名与 frontmatter name 统一前缀（默认 cc-，与 WF_AGENT_PREFIX 一致）
#   --only    逗号分隔，只装指定角色名（不带前缀，如 --only backend-developer）
#   --dry-run 只打印动作，不写盘
#
# 退出码：0 正常 / 2 参数或源目录错误

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
ROLE_LIB="$ROOT/通用角色库"

TARGET_DIR="$HOME/.claude/agents"
PREFIX="cc-"
ONLY=""
DRY_RUN=false

usage() {
  echo "用法：bash scripts/install-claude-agents.sh [--dry-run] [--dir <目标目录>] [--prefix <前缀>] [--only a,b,c]"
  echo "  --dir      目标目录（默认 ~/.claude/agents）"
  echo "  --prefix   文件名与 name 前缀（默认 cc-，与 WF_AGENT_PREFIX 一致）"
  echo "  --only     逗号分隔，只装指定角色名（不带前缀）"
  echo "  --dry-run  只打印动作，不写盘"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --dir)     TARGET_DIR="$2"; shift 2 ;;
    --prefix)  PREFIX="$2"; shift 2 ;;
    --only)    ONLY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[install-agents] 未知参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
done

[[ "$PREFIX" == */* ]] && { echo "[install-agents] --prefix 不能含斜杠：$PREFIX" >&2; exit 2; }
[[ "$PREFIX" == *[^a-zA-Z0-9_.-]* ]] && { echo "[install-agents] --prefix 仅允许字母数字_.-：$PREFIX" >&2; exit 2; }

# Windows 路径铁律：凡把路径交给原生程序（python 等）必须 C:/x/y 形式
native_path() { if command -v cygpath &>/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

if [[ ! -d "$ROLE_LIB" ]]; then
  echo "[install-agents] ✗ 角色库源目录不存在：$ROLE_LIB" >&2
  exit 2
fi

find_py() {
  if command -v python &>/dev/null; then command -v python
  elif command -v python3 &>/dev/null; then command -v python3
  else echo ""; fi
}
PY=$(find_py)
if [[ -z "$PY" ]]; then
  echo "[install-agents] ✗ 未找到 python（需要它做 hash 比对与 name: 改写）" >&2
  exit 2
fi

# ── Python 助手：hash 比对 + 首个 `name:` 行精确改写（不整块重排）──
# hash 模式：--hash <f1> <f2>  打印两文件 md5（不存在则打 MISSING）
# 装入模式：--install <src> <dst> <name>  复制并把 frontmatter 第一个 name: 行改为 <name>
run_py() {
  "$PY" - "$@" <<'PYEOF'
import hashlib, sys
from pathlib import Path

mode = sys.argv[1]
if mode == "--hash":
    for a in sys.argv[2:4]:
        p = Path(a)
        if not p.exists():
            print("MISSING")
        else:
            print(hashlib.md5(p.read_bytes()).hexdigest())
elif mode == "--hashn":
    # 两行输出：① src 改写（name: → <name>）后的 md5  ② dst 现有内容 md5（MISSING 表示不存在）
    # 比较/校验一律用「改写后」的值——装入的内容本来就不等于源文件，这是本脚本的核心语义
    src, name = sys.argv[2], sys.argv[4]
    p_src = Path(src)
    if not p_src.exists():
        sys.exit(2)
    lines = p_src.read_bytes().decode("utf-8").splitlines(keepends=True)
    if lines and lines[0].strip() == "---":
        try:
            end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
        except StopIteration:
            end = len(lines)
        for i in range(1, end):
            if lines[i].lstrip().startswith("name:"):
                eol = lines[i][len(lines[i].rstrip("\r\n")):]
                lines[i] = f"name: {name}{eol}"
                break
    print(hashlib.md5("".join(lines).encode("utf-8")).hexdigest())
    dst = Path(sys.argv[3])
    print(hashlib.md5(dst.read_bytes()).hexdigest() if dst.exists() else "MISSING")
elif mode == "--install":
    src, dst, name = sys.argv[2], sys.argv[3], sys.argv[4]
    # 用 bytes.decode 而非 read_text：后者在 Windows 上做 universal-newline
    # 转换（\r\n → \n），写回后 hash 必然与源不一致（实测踩过）
    text = Path(src).read_bytes().decode("utf-8")
    lines = text.splitlines(keepends=True)
    done = False
    # 只在 frontmatter（首个 --- 到闭合 --- 之间）内替换第一个 name: 行；
    # 正文中的 name:（如 devops.md 的 `name: CI`）一律不动
    if lines and lines[0].strip() == "---":
        try:
            end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
        except StopIteration:
            end = len(lines)
        for i in range(1, end):
            stripped = lines[i].lstrip()
            if stripped.startswith("name:"):
                eol = lines[i][len(lines[i].rstrip("\r\n")):]
                lines[i] = f"name: {name}{eol}"
                done = True
                break
    text = "".join(lines)
    if not done:
        # 无 name: 行 → 在首个 --- 后插入，CC 按 name 匹配，缺了会「装了但调不到」
        if text.startswith("---"):
            first_end = text.index("---") + 3
            nl = "\r\n" if "\r\n" in text[:first_end] else "\n"
            text = text[:first_end] + nl + f"name: {name}" + text[first_end:]
        else:
            text = f"---\nname: {name}\n---\n\n" + text
    Path(dst).write_text(text, encoding="utf-8", newline="")
else:
    sys.exit(2)
PYEOF
}

# ── 收集源文件：只取 通用角色库 顶层 .md（maxdepth 1 天然跳过 deprecated/ 子目录）──
mapfile -t src_files < <(find "$ROLE_LIB" -maxdepth 1 -name "*.md" -type f | sort)
if [[ ${#src_files[@]} -eq 0 ]]; then
  echo "[install-agents] ✗ 角色库为空：$ROLE_LIB" >&2
  exit 2
fi

# --only 过滤（不带前缀的裸角色名）
if [[ -n "$ONLY" ]]; then
  declare -A want=()
  IFS=',' read -ra only_list <<< "$ONLY"
  for n in "${only_list[@]}"; do [[ -n "$n" ]] && want["${n%.md}"]=1; done
  filtered=()
  for f in "${src_files[@]}"; do
    b=$(basename "$f" .md)
    [[ -n "${want[$b]:-}" ]] && filtered+=("$f")
  done
  if [[ ${#filtered[@]} -eq 0 ]]; then
    echo "[install-agents] ✗ --only 没匹配到任何角色：$ONLY（可用角色见 $ROLE_LIB）" >&2
    exit 2
  fi
  src_files=("${filtered[@]}")
fi

# ── 装之前先数目标目录，记录基线 ──
if [[ ! -d "$TARGET_DIR" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[install-agents] [dry-run] 目标目录不存在，将创建：$(native_path "$TARGET_DIR")"
  else
    echo "[install-agents] 目标目录不存在，创建：$(native_path "$TARGET_DIR")"
    mkdir -p "$TARGET_DIR"
  fi
fi
# 目标目录可能刚建/不存在 → find 报错须吞掉（set -euo pipefail 下否则整条管道 fail）
N_AT_START=$({ find "$TARGET_DIR" -maxdepth 1 -name "${PREFIX}*.md" -type f 2>/dev/null || true; } | wc -l)

P_SRC=$(native_path "$ROLE_LIB")
P_TGT=$(native_path "$TARGET_DIR")
N_INSTALL=0; N_UPDATE=0; N_SKIP=0

for src in "${src_files[@]}"; do
  b=$(basename "$src" .md)          # 裸角色名
  dst_name="${PREFIX}${b}.md"       # 文件名 = <prefix><源文件名>
  dst="${TARGET_DIR}/${dst_name}"

  hash_pair=$(run_py --hashn "$(native_path "$src")" "$(native_path "$dst")" "${PREFIX}${b}")
  src_h=$(echo "$hash_pair" | sed -n '1p')
  dst_h=$(echo "$hash_pair" | sed -n '2p')

  if [[ "$dst_h" == "MISSING" ]]; then
    ACT=INSTALL
  elif [[ "$src_h" == "$dst_h" ]]; then
    ACT=SKIP
  else
    ACT=UPDATE
  fi

  case "$ACT" in
    SKIP)
      N_SKIP=$((N_SKIP + 1))
      echo "  SKIP same  $dst_name"
      ;;
    INSTALL|UPDATE)
      # 计数在分支外：dry-run 也报「将要」的数量，不总是 0
      if [[ "$ACT" == "INSTALL" ]]; then N_INSTALL=$((N_INSTALL + 1)); else N_UPDATE=$((N_UPDATE + 1)); fi
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] $ACT  $dst_name"
      else
        native_dir="$P_TGT"
        native_src="$P_SRC/$(basename "$src")"
        mkdir -p "$TARGET_DIR"
        run_py --install "$(native_path "$src")" "$(native_path "$dst")" "${PREFIX}${b}"
        # 写后复核 (1)：比对装出的文件 hash 与「改写后」期望 hash
        chk=$(run_py --hashn "$(native_path "$src")" "$(native_path "$dst")" "${PREFIX}${b}")
        chk_dst=$(echo "$chk" | sed -n '2p')
        exp_h=$(echo "$chk" | sed -n '1p')
        if [[ "$chk_dst" != "$exp_h" ]]; then
          echo "[install-agents] ✗ 装入后校验失败：$dst_name" >&2
          exit 2
        fi
        # 写后复核 (2)：frontmatter 第一行 name 必须已带上前缀（CC 按 name 匹配）
        if ! grep -m1 -E "^name: ${PREFIX}" "$(native_path "$dst")" &>/dev/null; then
          echo "[install-agents] ✗ 装入后 name: 未改写（缺前缀）：$dst_name" >&2
          exit 2
        fi
        if [[ "$ACT" == "INSTALL" ]]; then echo "  INSTALL    $dst_name"; else echo "  UPDATE     $dst_name"; fi
      fi
      ;;
  esac
done

echo ""
echo "目标目录：$(native_path "$TARGET_DIR")（_PREFIX*=md 起始时刻已有 $N_AT_START 个）"
echo "源目录：$(native_path "$P_SRC")（跳过 deprecated/ 子目录）"
echo "汇总：INSTALL=$N_INSTALL UPDATE=$N_UPDATE SKIP=$N_SKIP"
echo "提示：用 claude -p --agent ${PREFIX}<name> 加载角色；不要用 Agent 工具派发（写文件会被权限弹窗卡死）"
exit 0
