#!/usr/bin/env python3
"""pipeline.py 核心单元测试（D1/D2：FakeRunner 注入，无需真跑 subprocess）

运行方式（二选一）：
    python -m pytest tests/test_pipeline.py -q
    python -m unittest tests.test_pipeline -v   # 无 pytest 时
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import pipeline  # noqa: E402
from pipeline import (  # noqa: E402
    CmdResult,
    PipelineContext,
    Stage,
    StageReport,
    Status,
    load_projects,
    orchestrate,
    resolve_config,
    resolve_test_cmd,
    run_stage_with_retry,
    stage_index,
)


class FakeRunner:
    """按队列返回预设结果，并记录所有调用。"""

    def __init__(self, results: list[CmdResult] | None = None):
        self.results = list(results or [])
        self.calls: list[tuple[list[str], str | None]] = []

    def run(self, cmd, cwd=None, timeout=300) -> CmdResult:
        self.calls.append((list(cmd), str(cwd) if cwd else None))
        if self.results:
            return self.results.pop(0)
        return CmdResult(0, "", "")


def make_ctx(**overrides) -> PipelineContext:
    defaults = dict(
        project="demo", task="测试任务", lang="python",
        skip_e2e=False, dry_run=True, only_analyze=False,
        from_stage="01-requirement",
    )
    defaults.update(overrides)
    return PipelineContext(**defaults)


PROJECTS = {
    "demo": {
        "path": "/tmp/demo",
        "workdir": "/tmp/demo",
        "lang": "python",
        "skip_e2e": True,
        "test_cmd": "pytest",
        "api_test_cmd": "pytest tests/api",
    },
}


class TestStageRegistry(unittest.TestCase):
    """B4/C4：阶段注册表与序号比较。"""

    def test_stage_ids_ordered(self):
        self.assertEqual(
            pipeline.STAGE_IDS,
            ["01-requirement", "02-code", "03-api-test", "04-e2e", "05-fix", "06-deliver"],
        )

    def test_stage_index(self):
        self.assertEqual(stage_index("01-requirement"), 0)
        self.assertEqual(stage_index("02-code"), 1)
        self.assertEqual(stage_index("06-deliver"), 5)
        self.assertEqual(stage_index("不存在"), -1)

    def test_from_stage_before_code_creates_worktree_logic(self):
        """from_stage 序号 <= 02 才创建 worktree —— 替代旧的字符串序比较。"""
        self.assertLessEqual(stage_index("01-requirement"), stage_index("02-code"))
        self.assertGreater(stage_index("03-api-test"), stage_index("02-code"))


class TestStatusConstants(unittest.TestCase):
    """B4：状态常量序列化兼容性。"""

    def test_serialized_values_unchanged(self):
        self.assertEqual(Status.SUCCESS, "success")
        self.assertEqual(Status.FAILED, "failed")
        self.assertEqual(Status.SKIPPED, "skipped")
        self.assertIn(Status.SUCCESS, Status.OK)
        self.assertIn(Status.SKIPPED, Status.OK)
        self.assertNotIn(Status.FAILED, Status.OK)


class TestLoadProjects(unittest.TestCase):
    """C2：外置 projects.yaml 加载。"""

    def test_load_from_explicit_yaml(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "projects.yaml"
            p.write_text(
                'proj-a:\n  path: "/data/a"\n  lang: go\n  skip_e2e: true\n  test_cmd: "go test ./..."\n',
                encoding="utf-8",
            )
            projects = load_projects(p)
        self.assertEqual(projects["proj-a"]["path"], "/data/a")
        self.assertEqual(projects["proj-a"]["lang"], "go")
        self.assertIs(projects["proj-a"]["skip_e2e"], True)
        self.assertEqual(projects["proj-a"]["test_cmd"], "go test ./...")

    def test_load_missing_returns_empty(self):
        self.assertEqual(load_projects(Path("/nonexistent/x.yaml")), {})

    def test_loaded_dict_is_independent_copy(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "projects.yaml"
            p.write_text('a:\n  path: "/x"\n', encoding="utf-8")
            p1 = load_projects(p)
            p1["a"]["path"] = "被修改"
            p2 = load_projects(p)
        self.assertEqual(p2["a"]["path"], "/x")


class TestResolveConfig(unittest.TestCase):
    """C2/E3：配置解析不污染输入。"""

    def test_unknown_project_returns_none(self):
        self.assertIsNone(resolve_config(make_ctx(project="ghost"), PROJECTS))

    def test_path_override(self):
        cfg = resolve_config(make_ctx(path_override="/elsewhere"), PROJECTS)
        self.assertEqual(cfg["path"], "/elsewhere")
        self.assertEqual(cfg["workdir"], "/elsewhere")
        # 原始 PROJECTS 不被污染
        self.assertEqual(PROJECTS["demo"]["path"], "/tmp/demo")

    def test_workdir_defaults_to_path(self):
        projects = {"p": {"path": "/only-path"}}
        cfg = resolve_config(make_ctx(project="p"), projects)
        self.assertEqual(cfg["workdir"], "/only-path")


class TestResolveTestCmd(unittest.TestCase):
    def test_api_test_cmd_priority(self):
        self.assertEqual(resolve_test_cmd(PROJECTS["demo"]), ["pytest", "tests/api"])

    def test_fallback_to_test_cmd(self):
        self.assertEqual(resolve_test_cmd({"test_cmd": "go test ./..."}), ["go", "test", "./..."])

    def test_missing_returns_none(self):
        self.assertIsNone(resolve_test_cmd({}))


class TestRunStageWithRetry(unittest.TestCase):
    """D1：重试/零产出分支的精确断言（旧架构无法测到这一层）。"""

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.ctx = make_ctx()
        self.ctx.report_dir = Path(self.td.name)

    def tearDown(self):
        self.td.cleanup()

    def _stage(self, fn) -> Stage:
        return Stage("99", "99-test", fn)

    def test_success_first_try_no_retry(self):
        calls = []

        def fn(ctx, cfg):
            calls.append(1)
            return StageReport(stage="99-test", status=Status.SUCCESS, end_time="t")

        r = run_stage_with_retry(self.ctx, {}, self._stage(fn))
        self.assertEqual(r.status, Status.SUCCESS)
        self.assertEqual(r.retry_count, 0)
        self.assertEqual(len(calls), 1)

    def test_retry_until_exhausted(self):
        def fn(ctx, cfg):
            return StageReport(stage="99-test", status=Status.FAILED,
                               error={"type": "X", "message": "普通失败"}, end_time="t")

        pipeline.RETRY_INTERVAL_SEC = 0  # 测试不真等
        r = run_stage_with_retry(self.ctx, {}, self._stage(fn))
        self.assertEqual(r.status, Status.FAILED)
        self.assertEqual(r.retry_count, pipeline.MAX_RETRIES)

    def test_zero_output_stops_without_retry(self):
        calls = []

        def fn(ctx, cfg):
            calls.append(1)
            return StageReport(stage="99-test", status=Status.FAILED,
                               error={"type": "X", "message": "委派零产出！"}, end_time="t")

        r = run_stage_with_retry(self.ctx, {}, self._stage(fn))
        self.assertEqual(len(calls), 1, "零产出应立即 STOP，不重试")
        self.assertEqual(r.retry_count, 0)

    def test_stage_report_written_to_disk(self):
        def fn(ctx, cfg):
            return StageReport(stage="99-test", status=Status.SUCCESS, end_time="t")

        run_stage_with_retry(self.ctx, {}, self._stage(fn))
        data = json.loads((Path(self.td.name) / "99-test.json").read_text(encoding="utf-8"))
        self.assertEqual(data["status"], "success")


class TestStageFunctionsWithFakeRunner(unittest.TestCase):
    """D1/D3：阶段函数在 FakeRunner 下的确定性行为。"""

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.workdir = Path(self.td.name)

    def tearDown(self):
        self.td.cleanup()

    def test_stage_01_missing_path_fails(self):
        ctx = make_ctx(dry_run=False)
        r = pipeline.stage_01_requirement(ctx, {"path": "/nonexistent-xyz"})
        self.assertEqual(r.status, Status.FAILED)
        self.assertEqual(r.error["type"], "FileNotFoundError")

    def test_stage_01_existing_path_succeeds(self):
        ctx = make_ctx(dry_run=False)
        r = pipeline.stage_01_requirement(ctx, {"path": str(self.workdir)})
        self.assertEqual(r.status, Status.SUCCESS)

    def test_stage_04_skip_e2e_flag(self):
        ctx = make_ctx(skip_e2e=True, dry_run=False)
        r = pipeline.stage_04_e2e(ctx, {})
        self.assertEqual(r.status, Status.SKIPPED)
        self.assertIn("--skip-e2e", r.output["reason"])

    def test_stage_04_skip_by_project_config(self):
        ctx = make_ctx(skip_e2e=False, dry_run=False)
        r = pipeline.stage_04_e2e(ctx, {"skip_e2e": True})
        self.assertEqual(r.status, Status.SKIPPED)

    def test_stage_04_unimplemented_fails_honestly(self):
        ctx = make_ctx(dry_run=False)
        r = pipeline.stage_04_e2e(ctx, {"frontend_url": "http://x"})
        self.assertEqual(r.status, Status.FAILED)
        self.assertEqual(r.error["type"], "NotImplemented")

    def test_stage_03_uses_injected_runner(self):
        runner = FakeRunner([CmdResult(0, "all passed", "")])
        ctx = make_ctx(dry_run=False, runner=runner)
        r = pipeline.stage_03_api_test(
            ctx, {"workdir": str(self.workdir), "api_test_cmd": "pytest tests/api"},
        )
        self.assertEqual(r.status, Status.SUCCESS)
        self.assertEqual(runner.calls[0][0], ["pytest", "tests/api"])

    def test_stage_03_test_failure(self):
        runner = FakeRunner([CmdResult(2, "", "1 failed")])
        ctx = make_ctx(dry_run=False, runner=runner)
        r = pipeline.stage_03_api_test(
            ctx, {"workdir": str(self.workdir), "test_cmd": "pytest"},
        )
        self.assertEqual(r.status, Status.FAILED)
        self.assertEqual(r.error["type"], "TestFailure")

    def test_stage_05_no_bugs_short_circuit(self):
        ctx = make_ctx(dry_run=False, runner=FakeRunner())
        r = pipeline.stage_05_fix(ctx, {"workdir": str(self.workdir)})
        self.assertEqual(r.status, Status.SUCCESS)
        self.assertIn("无失败用例", r.output["reason"])


class TestOrchestrate(unittest.TestCase):
    """B3/C4：编排驱动循环的端到端分支（全程 dry-run + FakeRunner）。"""

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.report_dir = Path(self.td.name) / "reports"

    def tearDown(self):
        self.td.cleanup()

    def test_unknown_project_exit_1(self):
        ctx = make_ctx(project="ghost")
        self.assertEqual(orchestrate(ctx, PROJECTS), 1)

    def test_only_analyze_runs_single_stage(self):
        ctx = make_ctx(only_analyze=True, report_dir=self.report_dir)
        with tempfile.TemporaryDirectory() as proj:
            projects = {"demo": {**PROJECTS["demo"], "path": proj, "workdir": proj}}
            rc = orchestrate(ctx, projects)
        self.assertEqual(rc, 0)
        self.assertEqual(list(ctx.reports.keys()), ["01-requirement"])
        self.assertTrue((self.report_dir / "pipeline-summary.json").exists())

    def test_dry_run_full_flow_all_ok(self):
        ctx = make_ctx(dry_run=True, skip_e2e=False, report_dir=self.report_dir)
        with tempfile.TemporaryDirectory() as proj:
            projects = {"demo": {**PROJECTS["demo"], "path": proj, "workdir": proj, "skip_e2e": False}}
            rc = orchestrate(ctx, projects)
        self.assertEqual(rc, 0)
        self.assertEqual(len(ctx.reports), 6)
        summary = json.loads((self.report_dir / "pipeline-summary.json").read_text(encoding="utf-8"))
        self.assertEqual(summary["overall_status"], "success")

    def test_from_stage_skips_earlier_stages(self):
        ctx = make_ctx(dry_run=True, from_stage="03-api-test", report_dir=self.report_dir)
        with tempfile.TemporaryDirectory() as proj:
            projects = {"demo": {**PROJECTS["demo"], "path": proj, "workdir": proj}}
            orchestrate(ctx, projects)
        self.assertNotIn("01-requirement", ctx.reports)
        self.assertNotIn("02-code", ctx.reports)
        self.assertIn("03-api-test", ctx.reports)


if __name__ == "__main__":
    unittest.main()
