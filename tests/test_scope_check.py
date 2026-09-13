#!/usr/bin/env python3
"""scope-check.py 单元测试（v4.4.2）

覆盖：路径规范化 / 重叠判定（含保守边界）/ 语义指纹 / 三种输入解析 /
退出码契约（0 通过、1 冲突、2 输入错误）/ --json 与 --lenient 行为。

运行：python -m unittest discover -s tests  或  python tests/test_scope_check.py
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import importlib.util

_spec = importlib.util.spec_from_file_location(
    "scope_check",
    Path(__file__).resolve().parent.parent / "scripts" / "scope-check.py",
)
scope_check = importlib.util.module_from_spec(_spec)
assert _spec and _spec.loader
# 必须先注册进 sys.modules：@dataclass 解析注解时依赖 sys.modules[cls.__module__]
sys.modules["scope_check"] = scope_check
_spec.loader.exec_module(scope_check)


class TestNormPath(unittest.TestCase):
    def test_backslash_and_trailing_slash(self):
        self.assertEqual(scope_check.norm_path("src\\auth\\"), "src/auth")

    def test_dot_prefix_and_duplicate_separators(self):
        self.assertEqual(scope_check.norm_path("./src//auth"), "src/auth")

    def test_case_folded_for_cross_platform_safety(self):
        self.assertEqual(scope_check.norm_path("Src/Auth"), "src/auth")

    def test_placeholder_and_quotes_stripped(self):
        self.assertEqual(scope_check.norm_path('"【src/auth】"'), "src/auth")


class TestOverlaps(unittest.TestCase):
    def test_identical(self):
        self.assertTrue(scope_check.overlaps("src/auth", "src/auth"))

    def test_parent_child_by_segment_boundary(self):
        self.assertTrue(scope_check.overlaps("src/auth", "src/auth/login.ts"))

    def test_sibling_prefix_is_not_overlap(self):
        # src/auth 不得吃掉 src/authz（按段边界比较）
        self.assertFalse(scope_check.overlaps("src/auth", "src/authz"))

    def test_same_dir_different_glob_extension(self):
        self.assertFalse(scope_check.overlaps("src/auth/*.ts", "src/auth/*.vue"))

    def test_glob_may_hit_literal_file(self):
        self.assertTrue(scope_check.overlaps("src/auth/*.ts", "src/auth/login.ts"))

    def test_global_glob_conflicts_with_everything(self):
        self.assertTrue(scope_check.overlaps("**", "docs/readme.md"))
        self.assertTrue(scope_check.overlaps("src/**", "src/a/b/c.ts"))

    def test_unrelated_dirs(self):
        self.assertFalse(scope_check.overlaps("src/api/", "tests/unit/"))

    def test_empty_entry_is_conservative_conflict(self):
        self.assertTrue(scope_check.overlaps("", "src/auth"))


class TestAnalyze(unittest.TestCase):
    def _task(self, tid, scope, goal="g", acceptance=()):
        return scope_check.TaskItem(
            task_id=tid, goal=goal, files_scope=list(scope),
            acceptance=list(acceptance),
        )

    def test_ok_when_disjoint(self):
        report = scope_check.analyze([
            self._task("T-001", ["src/auth/"]),
            self._task("T-002", ["src/billing/"]),
        ])
        self.assertTrue(report.ok)
        self.assertEqual(report.conflicts, [])
        self.assertEqual(report.serial_pairs, [])

    def test_conflict_reported_with_paths(self):
        report = scope_check.analyze([
            self._task("T-001", ["src/auth/"]),
            self._task("T-002", ["src/auth/login.ts"]),
        ])
        self.assertFalse(report.ok)
        self.assertEqual(report.serial_pairs, [["T-001", "T-002"]])
        self.assertIn("src/auth", report.conflicts[0]["paths"])

    def test_missing_scope_blocks_dispatch(self):
        report = scope_check.analyze([self._task("T-001", [])])
        self.assertFalse(report.ok)
        self.assertEqual(report.missing_scope, ["T-001"])

    def test_semantic_duplicate_detected(self):
        report = scope_check.analyze([
            self._task("T-001", ["src/auth/"], goal="实现登录", acceptance=["200"]),
            self._task("T-002", ["src/auth/"], goal="实现登录", acceptance=["200"]),
        ])
        self.assertEqual(report.duplicates, [["T-001", "T-002"]])

    def test_three_tasks_all_pairwise_checked(self):
        report = scope_check.analyze([
            self._task("T-001", ["src/"]),
            self._task("T-002", ["src/a"]),
            self._task("T-003", ["src/b"]),
        ])
        self.assertEqual(len(report.conflicts), 2)


class TestFingerprint(unittest.TestCase):
    def _item(self, **kw):
        base = dict(task_id="T-001", goal="实现登录", files_scope=["src/auth/"],
                    acceptance=["返回 200"])
        base.update(kw)
        return scope_check.TaskItem(**base)

    def test_stable_across_scope_order(self):
        a = scope_check.fingerprint(self._item(files_scope=["b/", "a/"]))
        b = scope_check.fingerprint(self._item(files_scope=["a/", "b/"]))
        self.assertEqual(a, b)

    def test_changes_with_goal(self):
        a = scope_check.fingerprint(self._item())
        b = scope_check.fingerprint(self._item(goal="实现登出"))
        self.assertNotEqual(a, b)

    def test_format_is_sha256_prefixed(self):
        self.assertRegex(scope_check.fingerprint(self._item()), r"^sha256:[0-9a-f]{16}$")


class TestParsing(unittest.TestCase):
    YAML = """
tasks:
  - id: t-001
    role: backend-developer
    task: "实现用户登录 API"
    files_scope:
      - src/auth/
      - tests/auth/
    max_turns: 10

  - id: t-002
    role: frontend-developer
    task: "实现登录页面组件"
    files_scope: [src/components/Login.vue]
"""

    CARD = """# 任务卡:【T-003】

## 一、基本信息

| 字段 | 内容 |
|------|------|
| 任务 ID | T-003 |
| 标题 | 实现用户登出 API |
| 文件边界 (files_scope) | src/auth/logout.ts, tests/auth/logout_test.ts |

## 三、完成标准（Definition of Done）

- [ ] 登出接口返回 204
- [ ] 单测覆盖 ≥ 80%
"""

    def test_parse_tasks_yaml_block_and_inline_lists(self):
        items = scope_check.parse_tasks_yaml(self.YAML)
        self.assertEqual([t.task_id for t in items], ["t-001", "t-002"])
        self.assertEqual(items[0].files_scope, ["src/auth/", "tests/auth/"])
        self.assertEqual(items[0].goal, "实现用户登录 API")
        self.assertEqual(items[1].files_scope, ["src/components/Login.vue"])

    def test_parse_card_markdown(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "任务卡_T-003.md"
            path.write_text(self.CARD, encoding="utf-8")
            item = scope_check.parse_card(path)
        self.assertEqual(item.task_id, "T-003")
        self.assertEqual(item.goal, "实现用户登出 API")
        self.assertEqual(
            item.files_scope, ["src/auth/logout.ts", "tests/auth/logout_test.ts"]
        )
        self.assertEqual(len(item.acceptance), 2)

    def test_parse_json_input_accepts_dict_and_list(self):
        payload = json.dumps({"tasks": [
            {"id": "T-9", "goal": "g", "files_scope": ["a/"], "acceptance": ["x"]}
        ]})
        items = scope_check.parse_json_input(payload)
        self.assertEqual(items[0].task_id, "T-9")
        self.assertEqual(items[0].acceptance, ["x"])

    def test_parse_json_input_rejects_garbage(self):
        with self.assertRaises(scope_check.InputError):
            scope_check.parse_json_input("{not json")


class TestCliContract(unittest.TestCase):
    def _run(self, argv, stdin: str = ""):
        buf = io.StringIO()
        old_stdin = sys.stdin
        sys.stdin = io.StringIO(stdin)
        try:
            with redirect_stdout(buf):
                rc = scope_check.main(argv)
        finally:
            sys.stdin = old_stdin
        return rc, buf.getvalue()

    def _write(self, td: str, name: str, text: str) -> str:
        path = Path(td) / name
        path.write_text(text, encoding="utf-8")
        return str(path)

    def test_exit_0_on_disjoint(self):
        with tempfile.TemporaryDirectory() as td:
            f = self._write(td, "t.yaml", """
tasks:
  - id: t-1
    task: "a"
    files_scope:
      - src/a/
  - id: t-2
    task: "b"
    files_scope:
      - src/b/
""")
            rc, out = self._run(["--tasks", f])
        self.assertEqual(rc, 0)
        self.assertIn("通过（可并行派发）", out)

    def test_exit_1_on_conflict(self):
        with tempfile.TemporaryDirectory() as td:
            f = self._write(td, "t.yaml", """
tasks:
  - id: t-1
    task: "a"
    files_scope:
      - src/a/
  - id: t-2
    task: "b"
    files_scope:
      - src/a/x.py
""")
            rc, out = self._run(["--tasks", f])
        self.assertEqual(rc, 1)
        self.assertIn("未通过", out)
        self.assertIn("t-1 ∩ t-2", out)

    def test_exit_2_on_missing_file(self):
        rc, out = self._run(["--tasks", "no-such-file.yaml"])
        self.assertEqual(rc, 2)

    def test_json_output_is_parseable(self):
        with tempfile.TemporaryDirectory() as td:
            f = self._write(td, "t.json", json.dumps([
                {"id": "T-1", "goal": "a", "files_scope": ["src/"]},
            ]))
            rc, out = self._run(["--json-input", f, "--json"])
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertTrue(data["ok"])
        self.assertEqual(data["task_count"], 1)
        self.assertIn("T-1", data["fingerprints"])

    def test_lenient_downgrades_missing_scope(self):
        with tempfile.TemporaryDirectory() as td:
            f = self._write(td, "t.json", json.dumps([{"id": "T-1", "goal": "a"}]))
            strict, _ = self._run(["--json-input", f])
            lenient, _ = self._run(["--json-input", f, "--lenient"])
        self.assertEqual(strict, 1)
        self.assertEqual(lenient, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
