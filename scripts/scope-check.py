#!/usr/bin/env python3
"""Hermes Scope Check — S4 派发前的文件边界互斥校验与语义指纹生成（v4.4.2）

背景：并行派发的前提是「并行不共写文件」（制度层 §二 军规 7）。但 Hermes 看板
平台明确**不做**并行卡之间的文件冲突检测（官方表述：Workers cannot see sibling
cards），这一层只能由套件自己守。本脚本是 S4 的准出工具：

  1. 解析一批任务的 files_scope（支持 tasks.yaml / 04 任务卡 markdown / JSON 三种输入）
  2. 两两做重叠判定（**保守策略**：宁可误报冲突，绝不漏报）
  3. 为每个任务生成语义指纹（semantic_hash）：指纹相同 = 语义重复子任务，
     应合并为一张卡；派发时把指纹用作 `hermes kanban create --idempotency-key`
     （平台语义：已存在同 key 的非归档卡 → 返回既有卡 id，天然防重复执行）

用法：
    python scripts/scope-check.py --tasks tasks.yaml
    python scripts/scope-check.py --cards doc/tasks/T-001.md doc/tasks/T-002.md
    python scripts/scope-check.py --json-input tasks.json --json
退出码：
    0 = 无重叠，可并行派发
    1 = 存在重叠或缺 files_scope（**禁止并行派发**）
    2 = 输入/解析错误
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

GLOB_CHARS = "*?["
PLACEHOLDER_RE = re.compile(r"[【】]")
SCOPE_SPLIT_RE = re.compile(r"[,，、;；\n]|<br\s*/?>", re.IGNORECASE)


# ════════════════════════════════════════════════════════════════
# 路径规范化与重叠判定
# ════════════════════════════════════════════════════════════════


def norm_path(raw: str) -> str:
    """把一条路径声明规范化为可比较形式。

    反斜杠转正斜杠、折叠重复分隔符、去引号与尾部斜杠、**统一转小写**。
    小写化是有意的保守选择：Windows/macOS 大小写不敏感，Linux 敏感，
    统一小写只会多报冲突（安全侧），不会漏报。
    """
    s = PLACEHOLDER_RE.sub("", str(raw)).strip().strip("\"'`")
    s = s.replace("\\", "/")
    s = re.sub(r"/{2,}", "/", s)
    while s.startswith("./"):
        s = s[2:]
    s = s.rstrip("/")
    return s.lower()


def split_scope_value(raw: str) -> list[str]:
    """把一条 files_scope 单元格/字符串拆成多条路径。"""
    return [p.strip() for p in SCOPE_SPLIT_RE.split(str(raw)) if p.strip()]


def literal_prefix(pattern: str) -> str:
    """取路径条目的「字面目录前缀」：遇到第一个含通配符的段就停止。"""
    parts = norm_path(pattern).split("/")
    kept: list[str] = []
    for seg in parts:
        if any(c in seg for c in GLOB_CHARS):
            break
        kept.append(seg)
    return "/".join(kept)


def glob_tail(pattern: str) -> str:
    """取最后一个通配段中 `*` 之后的字面尾巴（用于放宽同目录不同扩展名的误报）。

    `src/**/*.ts` → ".ts"；`src/login*` → ""（无法判定，保守视为冲突）。
    """
    last = norm_path(pattern).split("/")[-1]
    if "*" not in last:
        return ""
    return last.rsplit("*", 1)[1]


def overlaps(a: str, b: str) -> bool:
    """两条 files_scope 条目是否可能命中同一文件（保守判定）。"""
    na, nb = norm_path(a), norm_path(b)
    if not na or not nb:
        return True  # 空条目/纯通配 = 覆盖全仓，保守视为冲突
    if na == nb:
        return True

    pa, pb = literal_prefix(na), literal_prefix(nb)
    if not pa or not pb:
        return True  # 形如 `**` / `*/` 的全局通配，保守视为与任何路径冲突
    if pa == pb:
        # 同目录：两个都是通配且字面尾缀不同（*.ts vs *.vue）→ 判定为不冲突
        ta, tb = glob_tail(na), glob_tail(nb)
        if ta and tb and ta != tb:
            return False
        return True
    # 目录包含关系（按段边界比较，避免 src/auth 误吃 src/authz）
    return pa.startswith(pb + "/") or pb.startswith(pa + "/")


# ════════════════════════════════════════════════════════════════
# 语义指纹
# ════════════════════════════════════════════════════════════════


def normalize_text(raw: str) -> str:
    """目标/验收标准的文本规范化：折叠空白、去首尾、统一小写。"""
    return re.sub(r"\s+", " ", PLACEHOLDER_RE.sub("", str(raw))).strip().lower()


def fingerprint(task: "TaskItem") -> str:
    """语义指纹：sha256(目标 + 排序后的 files_scope + 排序后的验收标准)。

    相同指纹 = 语义等价子任务 → 应合并派发/复用已有卡，禁止重复执行。
    """
    payload = json.dumps(
        {
            "goal": normalize_text(task.goal),
            "scope": sorted({norm_path(s) for s in task.files_scope}),
            "acceptance": sorted(normalize_text(a) for a in task.acceptance),
        },
        ensure_ascii=False,
        sort_keys=True,
    )
    return "sha256:" + hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


# ════════════════════════════════════════════════════════════════
# 数据模型
# ════════════════════════════════════════════════════════════════


@dataclass
class TaskItem:
    task_id: str
    goal: str = ""
    files_scope: list[str] = field(default_factory=list)
    acceptance: list[str] = field(default_factory=list)
    source: str = ""


@dataclass
class Report:
    tasks: list[TaskItem] = field(default_factory=list)
    conflicts: list[dict[str, Any]] = field(default_factory=list)
    missing_scope: list[str] = field(default_factory=list)
    duplicates: list[list[str]] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.conflicts and not self.missing_scope

    @property
    def serial_pairs(self) -> list[list[str]]:
        return [[c["a"], c["b"]] for c in self.conflicts]

    @property
    def fingerprints(self) -> dict[str, str]:
        return {t.task_id: fingerprint(t) for t in self.tasks}

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "task_count": len(self.tasks),
            "conflicts": self.conflicts,
            "missing_scope": self.missing_scope,
            "duplicates": self.duplicates,
            "serial_pairs": self.serial_pairs,
            "fingerprints": self.fingerprints,
        }


def analyze(tasks: Iterable[TaskItem]) -> Report:
    """对一批任务做重叠检测 + 语义重复检测。"""
    items = [t for t in tasks]
    report = Report(tasks=items)

    for t in items:
        if not t.files_scope:
            report.missing_scope.append(t.task_id)

    for i, a in enumerate(items):
        for b in items[i + 1:]:
            hits: set[str] = set()
            for pa in a.files_scope:
                for pb in b.files_scope:
                    if overlaps(pa, pb):
                        hits.add(norm_path(pa))
                        hits.add(norm_path(pb))
            if hits:
                report.conflicts.append(
                    {"a": a.task_id, "b": b.task_id, "paths": sorted(hits)}
                )

    by_fp: dict[str, list[str]] = {}
    for t in items:
        by_fp.setdefault(fingerprint(t), []).append(t.task_id)
    report.duplicates = [ids for ids in by_fp.values() if len(ids) > 1]
    return report


# ════════════════════════════════════════════════════════════════
# 输入解析：tasks.yaml / 04 任务卡 markdown / JSON
# ════════════════════════════════════════════════════════════════


class InputError(ValueError):
    """无法解析输入时的错误（退出码 2）。"""


def _scalar(raw: str) -> Any:
    v = raw.strip()
    if not v:
        return ""
    if v[0] in "\"'" and v[-1:] == v[0]:
        return v[1:-1]
    return v


def parse_tasks_yaml(text: str) -> list[TaskItem]:
    """解析 agent-bridge `--tasks` 用的 YAML 子集（不依赖 pyyaml）。

    支持结构：
        tasks:
          - id: t-001
            task: "实现用户登录 API"
            files_scope:
              - src/auth/
              - tests/auth/
    """
    items: list[TaskItem] = []
    current: dict[str, Any] | None = None
    in_scope = False

    for raw_line in text.splitlines():
        line = raw_line.split(" #", 1)[0].rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        stripped = line.strip()
        if stripped == "tasks:":
            continue
        if stripped.startswith("- id:"):
            current = {"id": _scalar(stripped.split(":", 1)[1])}
            items.append(
                TaskItem(
                    task_id=str(current["id"]),
                    files_scope=[],
                    source="tasks.yaml",
                )
            )
            in_scope = False
            continue
        if current is None or not items:
            continue
        if stripped.startswith("files_scope:"):
            in_scope = True
            rest = stripped.split(":", 1)[1].strip()
            if rest.startswith("["):  # 行内数组写法
                for p in split_scope_value(rest.strip("[]")):
                    items[-1].files_scope.append(p)
                in_scope = False
            continue
        if stripped.startswith("- ") and in_scope:
            items[-1].files_scope.append(_scalar(stripped[2:]))
            continue
        in_scope = False
        if ":" in stripped:
            key, _, value = stripped.partition(":")
            key, value = key.strip(), _scalar(value)
            if key in ("task", "title", "goal"):
                items[-1].goal = str(value)
            elif key in ("acceptance", "acceptance_criteria"):
                for a in split_scope_value(value):
                    items[-1].acceptance.append(a)
    return items


def parse_card(path: Path) -> TaskItem:
    """解析 04 任务卡 markdown：任务 ID / 标题 / files_scope / 完成标准。"""
    text = path.read_text(encoding="utf-8", errors="replace")
    task_id = ""
    goal = ""
    scope_raw = ""
    acceptance: list[str] = []
    in_dod = False

    for line in text.splitlines():
        s = line.strip()
        if s.startswith("## "):
            in_dod = "完成标准" in s or "Definition of Done" in s
            continue
        if s.startswith("|"):
            cells = [c.strip() for c in s.strip("|").split("|")]
            if len(cells) >= 2:
                key, value = cells[0], cells[1]
                if key.startswith("任务 ID"):
                    task_id = PLACEHOLDER_RE.sub("", value).strip()
                elif key == "标题":
                    goal = PLACEHOLDER_RE.sub("", value).strip()
                elif "files_scope" in key:
                    scope_raw = value
        if in_dod and s.startswith("- ["):
            acceptance.append(PLACEHOLDER_RE.sub("", s[3:]).strip())

    if not task_id:
        task_id = path.stem
    return TaskItem(
        task_id=task_id,
        goal=goal,
        files_scope=split_scope_value(scope_raw),
        acceptance=[a for a in acceptance if a],
        source=str(path),
    )


def parse_json_input(text: str) -> list[TaskItem]:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise InputError(f"JSON 解析失败：{exc}") from exc
    if isinstance(data, dict):
        data = data.get("tasks", [])
    if not isinstance(data, list):
        raise InputError("JSON 输入必须是数组，或含 tasks 数组的对象")

    items: list[TaskItem] = []
    for row in data:
        if not isinstance(row, dict):
            raise InputError("JSON 数组元素必须是对象")
        scope = row.get("files_scope") or row.get("files_scope".upper()) or []
        if isinstance(scope, str):
            scope = split_scope_value(scope)
        acceptance = row.get("acceptance") or []
        if isinstance(acceptance, str):
            acceptance = split_scope_value(acceptance)
        items.append(
            TaskItem(
                task_id=str(row.get("id") or row.get("task_id") or "?"),
                goal=str(row.get("goal") or row.get("task") or row.get("title") or ""),
                files_scope=[str(s) for s in scope],
                acceptance=[str(a) for a in acceptance],
                source="json",
            )
        )
    return items


# ════════════════════════════════════════════════════════════════
# 输出
# ════════════════════════════════════════════════════════════════


def render_human(report: Report) -> str:
    lines = ["═══ 文件边界互斥校验（S4 准出）═══"]
    lines.append(
        f"任务数: {len(report.tasks)} ｜ 冲突对: {len(report.conflicts)}"
        f" ｜ 缺 files_scope: {len(report.missing_scope)}"
        f" ｜ 语义重复组: {len(report.duplicates)}"
    )
    lines.append(
        "结论: "
        + ("通过（可并行派发）" if report.ok else "未通过（禁止并行派发）")
    )
    for c in report.conflicts:
        lines.append(f"  ✗ {c['a']} ∩ {c['b']} → {', '.join(c['paths'])}（须改串行或重划边界）")
    for tid in report.missing_scope:
        lines.append(f"  ✗ {tid} 未声明 files_scope（04 模板硬规则：无边界不得派发）")
    for group in report.duplicates:
        lines.append(
            f"  ⚠ 语义重复组 {' = '.join(group)}（指纹相同，合并为一张卡，"
            "派发时复用同一 --idempotency-key）"
        )
    lines.append("语义指纹（用作 kanban --idempotency-key）:")
    for tid, fp in report.fingerprints.items():
        lines.append(f"  {tid} {fp}")
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="scope-check.py",
        description="S4 派发前的文件边界互斥校验 + 语义指纹生成",
    )
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--tasks", help="agent-bridge 任务文件（tasks.yaml）")
    src.add_argument("--cards", nargs="+", help="04 任务卡 markdown 文件或目录")
    src.add_argument("--json-input", help="JSON 任务数组文件（或 - 读 stdin）")
    p.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    p.add_argument(
        "--lenient",
        action="store_true",
        help="缺 files_scope 只警告不算失败（默认视为失败）",
    )
    return p


def _load(args: argparse.Namespace) -> list[TaskItem]:
    if args.tasks:
        path = Path(args.tasks)
        if not path.is_file():
            raise InputError(f"任务文件不存在：{path}")
        items = parse_tasks_yaml(path.read_text(encoding="utf-8", errors="replace"))
    elif args.cards:
        items = []
        for raw in args.cards:
            target = Path(raw)
            if target.is_dir():
                for f in sorted(target.glob("*.md")):
                    items.append(parse_card(f))
            elif target.is_file():
                items.append(parse_card(target))
            else:
                raise InputError(f"任务卡路径不存在：{target}")
    else:
        text = sys.stdin.read() if args.json_input == "-" else Path(
            args.json_input
        ).read_text(encoding="utf-8", errors="replace")
        items = parse_json_input(text)

    if not items:
        raise InputError("未解析到任何任务（检查输入格式是否匹配模板）")
    return items


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        items = _load(args)
    except InputError as exc:
        print(f"✗ 输入错误：{exc}", file=sys.stderr)
        return 2

    report = analyze(items)
    if args.lenient:
        report.missing_scope = []

    if args.json:
        print(json.dumps(report.as_dict(), ensure_ascii=False, indent=2))
    else:
        print(render_human(report))
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
