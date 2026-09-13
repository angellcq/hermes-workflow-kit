#!/usr/bin/env python3
"""kanban-dispatch.py 单元测试（v4.5.0）

覆盖：slug 生成 / 建卡命令拼装（幂等键、边界、平台熔断与完成契约透传）/
三闸门行为（边界冲突即拒发）/ CLI 退出码契约。

运行：python -m unittest discover -s tests  或  python tests/test_kanban_dispatch.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

_spec = importlib.util.spec_from_file_location(
    "kanban_dispatch", ROOT / "scripts" / "kanban-dispatch.py"
)
kanban_dispatch = importlib.util.module_from_spec(_spec)
assert _spec and _spec.loader
sys.modules["kanban_dispatch"] = kanban_dispatch
_spec.loader.exec_module(kanban_dispatch)


class TestSlugify(unittest.TestCase):
    def test_ascii_and_chinese(self):
        self.assertEqual(kanban_dispatch.slugify("实现登录 API"), "实现登录-api")

    def test_empty_falls_back(self):
        self.assertEqual(kanban_dispatch.slugify("!!!", "T-1"), "t-1")

    def test_length_capped(self):
        self.assertLessEqual(len(kanban_dispatch.slugify("a" * 100)), 40)


class TestBuildCreateCmd(unittest.TestCase):
    def _task(self):
        return kanban_dispatch._load_scope_check().TaskItem(
            task_id="T-001",
            goal="实现登录",
            files_scope=["src/auth/"],
        )

    def test_fingerprint_is_idempotency_key(self):
        cmd = kanban_dispatch.build_create_cmd(
            self._task(), "sha256:abc123", None, None, None, None
        )
        self.assertIn("--idempotency-key", cmd)
        self.assertEqual(cmd[cmd.index("--idempotency-key") + 1], "sha256:abc123")
        self.assertIn("T-001: 实现登录", cmd)
        self.assertEqual(cmd[-1], "--json")

    def test_platform_flags_passthrough(self):
        cmd = kanban_dispatch.build_create_cmd(
            self._task(), "sha256:x", "scope-smoke", "worktree", "claude", "coder",
            max_retries=1, max_runtime="2h",
            completion_contract="owner/repo", skills=["tidy"],
        )
        joined = " ".join(cmd)
        self.assertIn("--board scope-smoke", joined)
        self.assertIn("--workspace worktree", joined)
        self.assertIn("--branch claude/实现登录", joined)
        self.assertIn("--assignee coder", joined)
        self.assertIn("--max-retries 1", joined)
        self.assertIn("--max-runtime 2h", joined)
        self.assertIn("--completion-contract owner/repo", joined)
        self.assertIn("--skill tidy", joined)

    def test_optional_flags_absent_by_default(self):
        joined = " ".join(
            kanban_dispatch.build_create_cmd(
                self._task(), "sha256:x", None, None, None, None
            )
        )
        for flag in ("--max-retries", "--max-runtime", "--completion-contract",
                     "--skill", "--assignee", "--workspace"):
            self.assertNotIn(flag, joined)


class TestCliGates(unittest.TestCase):
    OK = """
tasks:
  - id: T-001
    task: "实现登录"
    files_scope:
      - src/auth/
  - id: T-002
    task: "实现登录页"
    files_scope:
      - src/components/Login.vue
"""

    OVERLAP = """
tasks:
  - id: T-001
    task: "实现登录"
    files_scope:
      - src/auth/
  - id: T-002
    task: "登录审计"
    files_scope:
      - src/auth/audit.ts
"""

    def _run(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = kanban_dispatch.main(argv)
        return rc, out.getvalue(), err.getvalue()

    def _write(self, td: str, name: str, text: str) -> str:
        path = Path(td) / name
        path.write_text(text, encoding="utf-8")
        return str(path)

    def test_dry_run_previews_and_exits_zero(self):
        with tempfile.TemporaryDirectory() as td:
            f = self._write(td, "t.yaml", self.OK)
            rc, out, _ = self._run(
                ["--tasks", f, "--dry-run", "--skip-preflight", "--json"]
            )
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertEqual(len(data["tasks"]), 2)
        for entry in data["tasks"]:
            self.assertEqual(entry["status"], "preview")
            self.assertTrue(entry["fingerprint"].startswith("sha256:"))

    def test_scope_conflict_blocks_all_cards(self):
        with tempfile.TemporaryDirectory() as td:
            f = self._write(td, "t.yaml", self.OVERLAP)
            rc, _, err = self._run(
                ["--tasks", f, "--dry-run", "--skip-preflight"]
            )
        self.assertEqual(rc, 1)
        self.assertIn("边界闸门未过", err)
        self.assertIn("禁止并行派发", err)

    def test_missing_file_exits_two(self):
        rc, _, err = self._run(["--tasks", "no-such.yaml", "--skip-preflight"])
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
