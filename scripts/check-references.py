#!/usr/bin/env python
"""引用完整性检查器 — Hermes Workflow Kit

扫描仓库内所有 .md/.sh/.py 文件中的仓内相对引用（Hermes模板库/ 通用角色库/ skills/ scripts/
及顶层文档），核对目标文件是否存在；同时检测已知失效引用模式。

用法：
    python scripts/check-references.py
退出码：0 = 全部通过；1 = 存在断链或失效模式。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 只检查这些仓库内部相对路径前缀（部署目标 ~/.hermes/、~/.claude/ 等不检）
REF_PREFIXES = ("Hermes模板库/", "通用角色库/", "skills/", "scripts/")

# 顶层文档也可被引用
TOP_DOCS = [p.name for p in ROOT.glob("*.md")] + [p.name for p in ROOT.glob("*.sh")]

# 已知失效模式（历史文件名），出现在以下文件之外即报错：
#   CHANGELOG.md               — 历史账本，允许记录旧文件名
#   Hermes模板库/编码规范_跨语言.md — 合并出处自述
STALE_PATTERNS = [
    "模板 11", "模板11", "模板 00", "模板00",
    "11_跨语言适配清单", "00_编码规范_通用",
    "README_改动说明",
]
STALE_ALLOWED_IN = {"CHANGELOG.md", "编码规范_跨语言.md", "check-references.py"}

# 部署路径前缀：出现在这些前缀之后的目录名不算仓内引用（如 ~/.hermes/Hermes模板库/...）
DEPLOY_PREFIX = ("~/",)

# 匹配 引用前缀 + 文件名字符（含中文）
REF_RE = re.compile(
    r"(?:Hermes模板库|通用角色库|skills|scripts)/[\w\-./\u4e00-\u9fff]+"
)


def iter_repo_files():
    for p in ROOT.rglob("*"):
        if p.suffix in (".md", ".sh", ".py") and ".git" not in p.parts:
            yield p


def strip_deploy_paths(line: str) -> str:
    """去掉部署路径段（~/... 开头直到下一个空白/反引号），避免 ~/.hermes/Hermes模板库/xxx 误报。"""
    return re.sub(r"~[^\s`）)｜|]*", " ", line)


def main() -> int:
    broken = []
    stale = []

    for path in iter_repo_files():
        rel = path.relative_to(ROOT).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            broken.append((rel, "<文件非 UTF-8 编码，无法检查>"))
            continue

        # 1) 引用目标存在性
        for lineno, line in enumerate(text.splitlines(), 1):
            clean = strip_deploy_paths(line)
            for m in REF_RE.finditer(clean):
                ref = m.group(0).rstrip("./")
                target = ROOT / ref
                if not target.exists():
                    broken.append((rel, f"L{lineno}: {ref}"))

        # 2) 顶层文档引用（CHANGELOG.md / DEPLOY.md 等裸文件名）
        for lineno, line in enumerate(text.splitlines(), 1):
            for doc in TOP_DOCS:
                if re.search(rf"(?<![\w/.-]){re.escape(doc)}", line):
                    if doc != path.name and not (ROOT / doc).exists():
                        broken.append((rel, f"L{lineno}: {doc}"))

        # 3) 已知失效模式
        if path.name in STALE_ALLOWED_IN:
            continue
        for pat in STALE_PATTERNS:
            for lineno, line in enumerate(text.splitlines(), 1):
                if pat in line:
                    # 编码规范_跨语言.md 之外的文件不许出现旧名
                    stale.append((rel, f"L{lineno}: 含失效引用 '{pat}'"))

    if broken:
        print(f"✗ 断链引用（{len(broken)} 处）：")
        for f, detail in broken:
            print(f"  {f} → {detail}")
    if stale:
        print(f"✗ 失效模式（{len(stale)} 处）：")
        for f, detail in stale:
            print(f"  {f} → {detail}")

    if not broken and not stale:
        print("✓ 引用完整性通过：无断链、无失效模式")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
