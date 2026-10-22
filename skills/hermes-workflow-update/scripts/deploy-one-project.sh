#!/usr/bin/env bash
# deploy-one-project.sh — 把 hermes-workflow-kit 镜像部署到单个项目的 .hermes/
#
# 用法:
#   bash deploy-one-project.sh <项目根>            # 纯覆盖+新增，不删任何东西
#   bash deploy-one-project.sh <项目根> --prune    # 真镜像：目标里源已无的文件一并删掉
#
# 环境变量:
#   SRC   套件源，缺省 F:/Gitee.com/hermes-workflow-kit
#   BAK   备份目录，缺省 <scratch>/deploy/<项目名>-<时间>.tgz 所在目录
#
# 为什么要有这个脚本：手工敲 tar 管道容易漏掉三件事——(1) 套件内**移动/删除**资产时
# tar -x 不会删目标里的旧副本（v5.0 把 5 个角色移进 deprecated/，目标顶层会留 5 个
# 陈旧 md，agent-bridge 扫描就数出 16 个，测试断言直接假红）；(2) 项目 CHANGELOG
# 常被追加本地条目，直接 cp 会丢；(3) 路径打错（盘符写错）时 tar 静默失败/建空目录，
# 要到校验阶段才暴露。这三件都硬化进脚本。
set -uo pipefail

SRC="${SRC:-F:/Gitee.com/hermes-workflow-kit}"
PROJ_ARG="${1:?用法: deploy-one-project.sh <项目根> [--prune]}"
PRUNE=0
[[ "${2:-}" == "--prune" ]] && PRUNE=1

PROJ="$(cygpath -m "$PROJ_ARG" 2>/dev/null || echo "$PROJ_ARG")"
NAME="$(basename "$PROJ")"
TS="$(date +%Y%m%d-%H%M%S)"
WORK="${TMPDIR:-/tmp}/deploy-$NAME-$TS"

# 0) 路径先断言（盘符写错时后面的 tar 会静默建空目录）
test -d "$PROJ/.hermes" || { echo "✗ $PROJ/.hermes 不存在——检查盘符/路径（D: 与 F: 别混）"; exit 2; }
test -d "$SRC"           || { echo "✗ 套件源 $SRC 不存在"; exit 2; }

mkdir -p "$WORK"
BAK="$WORK/$NAME-hermes.tgz"
tar --force-local -czf "$BAK" -C "$PROJ" .hermes && echo "[$NAME] 备份 → $BAK"

# 1) 项目 CHANGELOG 独有行（按行集合比，不按区间 —— 新版插入会让区间 diff 全错位）
CHANGELOG_EXTRA="$WORK/changelog-extra.txt"
: > "$CHANGELOG_EXTRA"
if [[ -f "$PROJ/.hermes/CHANGELOG.md" && -f "$SRC/CHANGELOG.md" ]]; then
  comm -13 <(sort -u "$SRC/CHANGELOG.md") <(sort -u "$PROJ/.hermes/CHANGELOG.md") > "$CHANGELOG_EXTRA"
  echo "[$NAME] 项目独有 CHANGELOG 行 = $(grep -c . "$CHANGELOG_EXTRA" || true)"
fi

# 2) 目录级镜像（tar 管道；同路径解包=覆盖，新增自动落地）
tar -c --exclude=__pycache__ -C "$SRC" Hermes模板库 skills config scripts 通用角色库 | tar -x -C "$PROJ/.hermes"
echo "[$NAME] 目录镜像完成"

# 3) 真镜像模式：删掉源已无的陈旧文件（tar 不会替你做这一步）
if [[ "$PRUNE" == "1" ]]; then
  for d in Hermes模板库 skills config scripts 通用角色库; do
    diff -rq "$PROJ/.hermes/$d" "$SRC/$d" 2>/dev/null \
      | sed -n "s|^Only in $PROJ/.hermes/\(.*\): \(.*\)$|$PROJ/.hermes/\1/\2|" \
      | while read -r f; do [[ -e "$f" ]] && rm -f "$f" && echo "[$NAME] 删除陈旧: ${f#$PROJ/.hermes/}"; done
  done
fi

# 4) 单文件覆盖（制度层去下划线）
cp "$SRC/Hermes_制度层.md" "$PROJ/.hermes/Hermes制度层.md"
cp "$SRC/通用角色库说明.md" "$PROJ/.hermes/通用角色库说明.md"
cp "$SRC/USAGE.md"        "$PROJ/.hermes/USAGE.md"
cp "$SRC/CHANGELOG.md"    "$PROJ/.hermes/CHANGELOG.md"

# 5) 项目独有 CHANGELOG 段补回末尾（不静默丢项目记录）
if [[ -s "$CHANGELOG_EXTRA" ]]; then
  { echo ""; echo "---"; echo ""; echo "## 项目局部记录（部署时保留）"; echo ""; cat "$CHANGELOG_EXTRA"; } >> "$PROJ/.hermes/CHANGELOG.md"
  echo "[$NAME] 项目独有 CHANGELOG 行已追加回末尾（$(grep -c . "$CHANGELOG_EXTRA") 行）"
fi

# 6) 校验：每目录两列指标 + 单文件精确比对 + 角色计数
echo "[$NAME] --- 校验 ---"
for d in Hermes模板库 skills config scripts 通用角色库; do
  only=$(diff -rq "$PROJ/.hermes/$d" "$SRC/$d" 2>/dev/null | grep -c "^Only in $PROJ")
  diffc=$(diff -rq "$PROJ/.hermes/$d" "$SRC/$d" 2>/dev/null | grep -c "^Files")
  echo "  $d: 目标多余=$only 内容不一致=$diffc"
done
for pair in "Hermes_制度层.md:Hermes制度层.md" "USAGE.md:USAGE.md" "通用角色库说明.md:通用角色库说明.md"; do
  s="${pair%%:*}"; t="${pair##*:}"
  if [[ "$(md5sum "$SRC/$s" | cut -d' ' -f1)" == "$(md5sum "$PROJ/.hermes/$t" | cut -d' ' -f1)" ]]; then
    echo "  $t: 逐字节一致"
  else
    echo "  $t: ✗ 不一致"
  fi
done
echo "[$NAME] 角色=$(ls "$PROJ/.hermes/通用角色库"/*.md 2>/dev/null | wc -l) 废弃=$(ls "$PROJ/.hermes/通用角色库/deprecated"/*.md 2>/dev/null | wc -l) 文件总数=$(find "$PROJ/.hermes" -type f -not -path '*/__pycache__/*' | wc -l)"
echo "[$NAME] 源版本=$(git -C "$SRC" log --oneline -1)"
