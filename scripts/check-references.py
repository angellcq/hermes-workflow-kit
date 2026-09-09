#!/usr/bin/env python
"""引用完整性检查器 v2 — Hermes Workflow Kit

三级检查：
  1. 文件级：仓内相对引用（Hermes模板库/ 通用角色库/ skills/ scripts/ 及顶层文档）目标存在性
  2. 章节级（E2 契约）：`xxx.md §anchor` 引用的章节在目标文件中真实存在
     - 支持中文数字锚点（§十二）与阿拉伯锚点（§17.1 / §5）
     - 支持混合锚点（§六.5 = 第六章第 5 节，匹配标题 `### 6.5 ...`）
     - 支持文件别名（AGENTS.md → Hermes_制度层.md，SOUL.md → Hermes_主人格.md）
  3. 失效模式：已知历史文件名（清单外置 config/stale-patterns.txt，缺省用内置）

用法：
    python scripts/check-references.py
退出码：0 = 全部通过；1 = 存在断链/章节缺失/失效模式。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 只检查这些仓库内部相对路径前缀（部署目标 ~/.hermes/、~/.claude/ 等不检）
REF_PREFIXES = ("Hermes模板库/", "通用角色库/", "skills/", "scripts/")

# 顶层文档也可被引用
TOP_DOCS = [p.name for p in ROOT.glob("*.md")] + [p.name for p in ROOT.glob("*.sh")]

# 文件别名：文档中的惯用称呼 → 仓内真实文件
FILE_ALIASES = {
    "AGENTS.md": "Hermes_制度层.md",
    "SOUL.md": "Hermes_主人格.md",
}

# 失效模式清单：外置文件优先，内置兜底
BUILTIN_STALE = [
    "模板 11", "模板11", "模板 00", "模板00",
    "11_跨语言适配清单", "00_编码规范_通用",
    "README_改动说明",
]
STALE_ALLOWED_IN = {"CHANGELOG.md", "编码规范_跨语言.md", "check-references.py"}

# 章节引用豁免：CHANGELOG 是历史账本，允许引用已不存在的章节
SECTION_CHECK_EXEMPT = {"CHANGELOG.md"}

# 匹配 引用前缀 + 文件名字符（含中文）
REF_RE = re.compile(
    r"(?:Hermes模板库|通用角色库|skills|scripts)/[\w\-./\u4e00-\u9fff]+"
)

# 匹配 `文件名.md §锚点`（锚点：中文数字 / 阿拉伯 / 混合点分）
SECTION_REF_RE = re.compile(
    r"([\w\u4e00-\u9fff.-]+\.md)\s*§([〇一二三四五六七八九十0-9]+(?:\.[0-9]+)*)"
)

# 标题行：## 十二、xxx / ### 6.5 xxx / ## 〇、xxx
HEADING_TOKEN_RE = re.compile(
    r"^#{1,6}\s+([〇一二三四五六七八九十]+|[0-9]+(?:\.[0-9]+)*)[、.\s]"
)

# 步骤标记（代码块/注释中的 `# ═══ 5. xxx` 或行首 `5. xxx`）
STEP_TOKEN_RE = re.compile(r"^\D{0,12}([0-9]+(?:\.[0-9]+)*)[.、]\s*\S")

CN_DIGITS = {"〇": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
             "六": 6, "七": 7, "八": 8, "九": 9}


def cn_to_int(text: str) -> int | None:
    """中文数字 → 阿拉伯（支持 〇~九十九）。"""
    if not text:
        return None
    if text.isdigit():
        return int(text)
    if "十" in text:
        left, _, right = text.partition("十")
        tens = CN_DIGITS.get(left, 1) if left else 1
        ones = CN_DIGITS.get(right, 0) if right else 0
        if (left and left not in CN_DIGITS) or (right and right not in CN_DIGITS):
            return None
        return tens * 10 + ones
    return CN_DIGITS.get(text)


def canonical_anchor(anchor: str) -> str | None:
    """锚点规范化：每段转为阿拉伯数字，点分连接。§六.5 → 6.5；§十八 → 18。"""
    parts = []
    for seg in anchor.split("."):
        n = cn_to_int(seg)
        if n is None:
            return None
        parts.append(str(n))
    return ".".join(parts)


def extract_section_tokens(path: Path) -> set[str]:
    """提取文件中所有可被 § 引用的章节令牌（规范化后）。"""
    tokens: set[str] = set()
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return tokens
    for line in text.splitlines():
        m = HEADING_TOKEN_RE.match(line)
        if m:
            canon = canonical_anchor(m.group(1))
            if canon:
                tokens.add(canon)
            continue
        m = STEP_TOKEN_RE.match(line)
        if m:
            canon = canonical_anchor(m.group(1))
            if canon:
                tokens.add(canon)
    return tokens


def load_stale_patterns() -> list[str]:
    cfg = ROOT / "config" / "stale-patterns.txt"
    if cfg.exists():
        patterns = [
            line.strip() for line in cfg.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        if patterns:
            return patterns
    return BUILTIN_STALE


def iter_repo_files():
    for p in ROOT.rglob("*"):
        if p.suffix in (".md", ".sh", ".py") and ".git" not in p.parts:
            yield p


def strip_deploy_paths(line: str) -> str:
    """去掉部署路径段（~/... 开头直到下一个空白/反引号），避免 ~/.hermes/Hermes模板库/xxx 误报。"""
    return re.sub(r"~[^\s`）)｜|]*", " ", line)


def resolve_doc(name: str) -> Path | None:
    """按文件名（或别名）在仓内定位文档。"""
    real = FILE_ALIASES.get(name, name)
    candidate = ROOT / real
    if candidate.exists():
        return candidate
    matches = [p for p in ROOT.rglob(real) if ".git" not in p.parts]
    return matches[0] if matches else None


def main() -> int:
    broken: list[tuple[str, str]] = []
    stale: list[tuple[str, str]] = []
    missing_sections: list[tuple[str, str]] = []
    stale_patterns = load_stale_patterns()

    # 章节令牌缓存
    token_cache: dict[Path, set[str]] = {}

    def tokens_of(doc: Path) -> set[str]:
        if doc not in token_cache:
            token_cache[doc] = extract_section_tokens(doc)
        return token_cache[doc]

    for path in iter_repo_files():
        rel = path.relative_to(ROOT).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            broken.append((rel, "<文件非 UTF-8 编码，无法检查>"))
            continue

        # 1) 文件级：引用目标存在性
        for lineno, line in enumerate(text.splitlines(), 1):
            clean = strip_deploy_paths(line)
            for m in REF_RE.finditer(clean):
                ref = m.group(0).rstrip("./")
                if not (ROOT / ref).exists():
                    broken.append((rel, f"L{lineno}: {ref}"))

        # 2) 文件级：顶层文档裸文件名引用
        for lineno, line in enumerate(text.splitlines(), 1):
            for doc in TOP_DOCS:
                if re.search(rf"(?<![\w/.-]){re.escape(doc)}", line):
                    if doc != path.name and not (ROOT / doc).exists():
                        broken.append((rel, f"L{lineno}: {doc}"))

        # 3) 章节级：xxx.md §anchor 契约检查
        if path.name not in SECTION_CHECK_EXEMPT:
            for lineno, line in enumerate(text.splitlines(), 1):
                for m in SECTION_REF_RE.finditer(line):
                    doc_name, anchor = m.group(1), m.group(2)
                    doc = resolve_doc(doc_name)
                    if doc is None:
                        broken.append((rel, f"L{lineno}: 引用的文档不存在 {doc_name}"))
                        continue
                    canon = canonical_anchor(anchor)
                    if canon and canon not in tokens_of(doc):
                        missing_sections.append(
                            (rel, f"L{lineno}: {doc_name} §{anchor}（目标文件无此章节）")
                        )

        # 4) 失效模式
        if path.name in STALE_ALLOWED_IN:
            continue
        for pat in stale_patterns:
            for lineno, line in enumerate(text.splitlines(), 1):
                if pat in line:
                    stale.append((rel, f"L{lineno}: 含失效引用 '{pat}'"))

    if broken:
        print(f"✗ 断链引用（{len(broken)} 处）：")
        for f, detail in broken:
            print(f"  {f} → {detail}")
    if missing_sections:
        print(f"✗ 章节缺失（{len(missing_sections)} 处）：")
        for f, detail in missing_sections:
            print(f"  {f} → {detail}")
    if stale:
        print(f"✗ 失效模式（{len(stale)} 处）：")
        for f, detail in stale:
            print(f"  {f} → {detail}")

    total = len(broken) + len(missing_sections) + len(stale)
    if total == 0:
        print("✓ 引用完整性通过：文件级 + 章节级 + 失效模式 全部干净")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
