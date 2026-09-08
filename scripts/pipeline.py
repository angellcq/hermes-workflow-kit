#!/usr/bin/env python3
"""
Hermes Pipeline — 端到端 6 阶段自动化交付流水线（融合版 v4.0）

阶段流转：需求分析 → 代码开发 → 接口测试 → 页面联调（可选）→ 缺陷修复 → 交付归档
每阶段最多 2 次重试，间隔 5s；失败自动升级。

Usage:
    python pipeline.py --project my-app --task "实现用户登录接口"
    python pipeline.py --project my-app --task "..." --skip-e2e
    python pipeline.py --project my-app --task "..." --from-stage 03
    python pipeline.py --project my-app --task "..." --only-analyze
    python pipeline.py --project my-app --task "..." --dry-run
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime
from pathlib import Path
from typing import Any

# ════════════════════════════════════════════════════════════════
# 项目配置（按需修改）
# ════════════════════════════════════════════════════════════════

PROJECTS: dict[str, dict[str, Any]] = {
    "my-app": {
        "path": r"D:\projects\my-app",
        "lang": "python",
        "frontend_url": "http://localhost:3000",
        "backend_base": "http://localhost:8080",
        "claude_workdir": r"D:\projects\my-app",
        "skip_e2e": False,
        "test_cmd": "pytest",
        "api_test_cmd": "pytest tests/api",
        "build_cmd": "make build",
    },
    # 模板：按以下结构添加新项目
    # "another-project": {
    #     "path": r"D:\path\to\project",
    #     "lang": "go",
    #     "frontend_url": "http://localhost:8080",
    #     "backend_base": "http://localhost:9000",
    #     "claude_workdir": r"D:\path\to\project",
    #     "skip_e2e": True,
    #     "test_cmd": "go test ./...",
    #     "api_test_cmd": "go test ./tests/api/...",
    #     "build_cmd": "go build ./...",
    # },
}

# ════════════════════════════════════════════════════════════════
# 全局配置
# ════════════════════════════════════════════════════════════════

HOME = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
REPORT_BASE = Path.home() / ".workbuddy" / "pipeline-reports"
MAX_RETRIES = 2
RETRY_INTERVAL_SEC = 5
FIX_MAX_ROUNDS = 2  # 修复阶段最多 2 轮
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "claude")
CLAUDE_MAX_TURNS_DEFAULT = 15


# ════════════════════════════════════════════════════════════════
# 数据结构
# ════════════════════════════════════════════════════════════════


@dataclass
class StageReport:
    stage: str
    status: str  # success | failed | retrying | skipped
    start_time: str = ""
    end_time: str = ""
    duration_seconds: float = 0.0
    retry_count: int = 0
    input: dict[str, Any] = field(default_factory=dict)
    output: dict[str, Any] = field(default_factory=dict)
    error: dict[str, Any] | None = None

    def to_json(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class PipelineContext:
    project: str
    task: str
    lang: str
    skip_e2e: bool
    dry_run: bool
    only_analyze: bool
    from_stage: str
    worktree_path: Path | None = None
    reports: dict[str, StageReport] = field(default_factory=dict)
    report_dir: Path | None = None


# ════════════════════════════════════════════════════════════════
# 工具函数
# ════════════════════════════════════════════════════════════════


def now_iso() -> str:
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S%z") or \
        datetime.now().isoformat()


def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def run_cmd(cmd: list[str], cwd: Path | None = None, timeout: int = 300) -> tuple[int, str, str]:
    """执行命令并返回 (returncode, stdout, stderr)"""
    try:
        result = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            shell=isinstance(cmd, str),
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", f"Timeout after {timeout}s"
    except FileNotFoundError as e:
        return -1, "", str(e)


def git_diff_stat(workdir: Path) -> tuple[int, str]:
    """返回 (变更文件数, diff_stat 输出)"""
    rc, out, _ = run_cmd(["git", "diff", "--stat", "HEAD"], cwd=workdir)
    if rc != 0:
        return 0, ""
    files = [line for line in out.splitlines() if "|" in line]
    return len(files), out.strip()


def git_status_short(workdir: Path) -> str:
    rc, out, _ = run_cmd(["git", "status", "--short"], cwd=workdir)
    return out.strip() if rc == 0 else ""


# ════════════════════════════════════════════════════════════════
# 阶段 01：需求分析
# ════════════════════════════════════════════════════════════════


def stage_01_requirement(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [01 需求分析] ═══")
    report = StageReport(stage="01-requirement", status="running", start_time=now_iso())
    report.input = {"task": ctx.task, "project_path": cfg["path"]}

    try:
        project_path = Path(cfg["path"])
        if not project_path.exists():
            raise FileNotFoundError(f"项目路径不存在：{cfg['path']}")

        # 读取项目上下文
        readme_content = ""
        for fname in ("README.md", "AGENTS.md", "AGENT.md", ".hermes.md"):
            fpath = project_path / fname
            if fpath.exists():
                readme_content += f"\n=== {fname} ===\n" + fpath.read_text(encoding="utf-8", errors="ignore")[:2000]

        # 读取最近 git log
        rc, git_log, _ = run_cmd(["git", "log", "--oneline", "-10"], cwd=project_path)
        recent_commits = git_log if rc == 0 else "(无 git 历史)"

        # 简化的需求分析（实际可由 Hermes LLM 调用补充）
        requirements = {
            "task_description": ctx.task,
            "project": ctx.project,
            "language": ctx.lang,
            "project_context": readme_content[:1500],
            "recent_commits": recent_commits,
            "files_scope": "【由 Hermes 在派发前细化】",
            "acceptance": [
                f"完成：{ctx.task}",
                "代码通过编译/语法检查",
                "相关测试通过",
                "无回归（已有测试全部通过）",
            ],
            "dependencies": [],
        }

        if ctx.dry_run:
            log("  [dry-run] 跳过实际分析")
            requirements["dry_run"] = True

        report.status = "success"
        report.output = requirements
        log(f"  ✓ 需求分析完成（acceptance: {len(requirements['acceptance'])} 项）")

    except Exception as e:
        report.status = "failed"
        report.error = {"type": type(e).__name__, "message": str(e)}
        log(f"  ✗ 需求分析失败：{e}")

    report.end_time = now_iso()
    return report


# ════════════════════════════════════════════════════════════════


def stage_02_code(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [02 代码开发] ═══")
    report = StageReport(stage="02-code", status="running", start_time=now_iso())
    report.input = {"task": ctx.task, "worktree": str(ctx.worktree_path)}

    if ctx.dry_run:
        log("  [dry-run] 跳过实际编码")
        report.status = "success"
        report.output = {"dry_run": True}
        report.end_time = now_iso()
        return report

    try:
        workdir = ctx.worktree_path or Path(cfg["claude_workdir"])
        workdir.mkdir(parents=True, exist_ok=True)

        # 写 TASK.md（防空任务）
        task_md = workdir / "TASK.md"
        task_md.write_text(
            f"""# 任务：{ctx.task}

## 项目
- 名称：{ctx.project}
- 路径：{cfg['path']}
- 语言：{ctx.lang}

## 上下文
{ctx.reports.get('01-requirement', StageReport(stage='01')).output.get('project_context', '')[:1000]}

## 验收标准
{chr(10).join('- ' + a for a in ctx.reports.get('01-requirement', StageReport(stage='01')).output.get('acceptance', []))}

## 完成定义
1. 所有验收标准达成
2. 编译/语法检查通过
3. 已有测试不被破坏
4. 修改文件清单 + diff 摘要输出

## 工作目录
{workdir}
""",
            encoding="utf-8",
        )

        # 调用 claude -p（防空任务：只让 claude 读 TASK.md）
        cmd = [
            CLAUDE_BIN, "-p",
            "读 TASK.md 并执行。完成后输出：\n1. 修改文件清单\n2. diff 摘要\n3. 任何阻塞/偏差",
            "--allowedTools", "Read,Edit,Write,Bash,Grep",
            "--max-turns", str(CLAUDE_MAX_TURNS_DEFAULT),
            "--output-format", "json",
        ]

        rc, stdout, stderr = run_cmd(cmd, cwd=workdir, timeout=600)

        if rc != 0:
            raise RuntimeError(f"claude -p 退出码 {rc}: {stderr[:500]}")

        # 验证产出：必须有 git 变更
        diff_count, diff_stat = git_diff_stat(workdir)
        if diff_count == 0:
            raise RuntimeError(
                "委派零产出！git diff 为空。\n"
                "STOP：转手动 patch，不重试。\n"
                f"stdout: {stdout[:500]}"
            )

        report.status = "success"
        report.output = {
            "files_changed_count": diff_count,
            "diff_stat": diff_stat,
            "claude_stdout_preview": stdout[:1000],
        }
        log(f"  ✓ 代码开发完成（{diff_count} 个文件变更）")

    except Exception as e:
        report.status = "failed"
        report.error = {"type": type(e).__name__, "message": str(e)}
        log(f"  ✗ 代码开发失败：{e}")

    report.end_time = now_iso()
    return report


# ════════════════════════════════════════════════════════════════


def stage_03_api_test(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [03 接口测试] ═══")
    report = StageReport(stage="03-api-test", status="running", start_time=now_iso())
    report.input = {"test_cmd": cfg.get("api_test_cmd")}

    if ctx.dry_run:
        report.status = "success"
        report.output = {"dry_run": True}
        report.end_time = now_iso()
        log("  [dry-run] 跳过接口测试")
        return report

    try:
        workdir = ctx.worktree_path or Path(cfg["claude_workdir"])
        test_cmd = cfg.get("api_test_cmd") or cfg.get("test_cmd")
        if not test_cmd:
            raise ValueError("PROJECTS 配置缺少 test_cmd 或 api_test_cmd")

        # 拆分命令
        cmd_parts = test_cmd.split() if isinstance(test_cmd, str) else test_cmd
        rc, stdout, stderr = run_cmd(cmd_parts, cwd=workdir, timeout=300)

        # 简单的通过/失败判断（实际可解析 junit xml 等）
        passed = rc == 0
        report.output = {
            "returncode": rc,
            "passed": passed,
            "stdout_tail": stdout[-1000:] if stdout else "",
            "stderr_tail": stderr[-500:] if stderr else "",
        }

        if passed:
            report.status = "success"
            log("  ✓ 接口测试通过")
        else:
            report.status = "failed"
            report.error = {"type": "TestFailure", "message": f"测试退出码 {rc}"}
            log(f"  ✗ 接口测试失败（退出码 {rc}）")

    except Exception as e:
        report.status = "failed"
        report.error = {"type": type(e).__name__, "message": str(e)}
        log(f"  ✗ 接口测试异常：{e}")

    report.end_time = now_iso()
    return report


# ════════════════════════════════════════════════════════════════


def stage_04_e2e(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [04 页面联调] ═══")
    report = StageReport(stage="04-e2e", status="running", start_time=now_iso())

    if ctx.skip_e2e:
        report.status = "skipped"
        report.output = {"reason": "用户指定 --skip-e2e"}
        report.end_time = now_iso()
        log("  ⊘ 跳过页面联调（--skip-e2e）")
        return report

    if cfg.get("skip_e2e"):
        report.status = "skipped"
        report.output = {"reason": "项目配置 skip_e2e=True"}
        report.end_time = now_iso()
        log("  ⊘ 跳过页面联调（项目配置）")
        return report

    if ctx.dry_run:
        report.status = "success"
        report.output = {"dry_run": True}
        report.end_time = now_iso()
        log("  [dry-run] 跳过页面联调")
        return report

    try:
        # 这里集成 Playwright MCP（实际实现需 MCP 客户端）
        # 占位实现：仅检查 frontend_url 是否可达
        import urllib.request

        frontend_url = cfg.get("frontend_url", "http://localhost:3000")
        try:
            with urllib.request.urlopen(frontend_url, timeout=10) as resp:
                status_code = resp.status
                report.output = {
                    "url": frontend_url,
                    "status_code": status_code,
                    "reachable": status_code < 400,
                }
                if status_code < 400:
                    report.status = "success"
                    log(f"  ✓ 前端可达（HTTP {status_code}）")
                else:
                    report.status = "failed"
                    report.error = {"type": "HTTPError", "message": f"HTTP {status_code}"}
                    log(f"  ✗ 前端返回 HTTP {status_code}")
        except Exception as e:
            report.status = "failed"
            report.error = {"type": "Unreachable", "message": str(e)}
            log(f"  ✗ 前端不可达：{e}")

    except Exception as e:
        report.status = "failed"
        report.error = {"type": type(e).__name__, "message": str(e)}
        log(f"  ✗ 页面联调异常：{e}")

    report.end_time = now_iso()
    return report


# ════════════════════════════════════════════════════════════════


def stage_05_fix(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [05 缺陷修复] ═══")
    report = StageReport(stage="05-fix", status="running", start_time=now_iso())

    if ctx.dry_run:
        report.status = "success"
        report.output = {"dry_run": True}
        report.end_time = now_iso()
        log("  [dry-run] 跳过修复")
        return report

    try:
        workdir = ctx.worktree_path or Path(cfg["claude_workdir"])

        # 收集失败用例
        bugs = []
        for stage_id in ("03-api-test", "04-e2e"):
            s = ctx.reports.get(stage_id)
            if s and s.status == "failed":
                bugs.append({
                    "stage": stage_id,
                    "error": s.error,
                })

        if not bugs:
            report.status = "success"
            report.output = {"reason": "无失败用例，无需修复"}
            log("  ✓ 无失败用例")
            report.end_time = now_iso()
            return report

        # 写 BUGS.md
        bugs_md = workdir / "BUGS.md"
        bugs_md.write_text(
            "# 失败用例汇总\n\n" +
            "\n".join(f"## {b['stage']}\n```json\n{json.dumps(b['error'], ensure_ascii=False, indent=2)}\n```\n" for b in bugs),
            encoding="utf-8",
        )

        # 多轮修复（最多 FIX_MAX_ROUNDS）
        for round_idx in range(1, FIX_MAX_ROUNDS + 1):
            log(f"  修复轮次 {round_idx}/{FIX_MAX_ROUNDS}")

            cmd = [
                CLAUDE_BIN, "-p",
                "读 BUGS.md 并修复。修复后跑测试确认通过。",
                "--allowedTools", "Read,Edit,Write,Bash,Grep",
                "--max-turns", "10",
            ]
            rc, stdout, stderr = run_cmd(cmd, cwd=workdir, timeout=300)

            if rc != 0:
                log(f"  claude 退出码 {rc}")
                continue

            # 验证修复
            diff_count, _ = git_diff_stat(workdir)
            if diff_count == 0:
                log("  修复无产出，停止")
                break

            # 重跑接口测试
            test_cmd = cfg.get("api_test_cmd") or cfg.get("test_cmd")
            if test_cmd:
                cmd_parts = test_cmd.split() if isinstance(test_cmd, str) else test_cmd
                rc_test, _, _ = run_cmd(cmd_parts, cwd=workdir, timeout=300)
                if rc_test == 0:
                    report.status = "success"
                    report.output = {
                        "rounds_used": round_idx,
                        "fixed": True,
                        "diff_count": diff_count,
                    }
                    log(f"  ✓ 修复成功（{round_idx} 轮）")
                    break
        else:
            report.status = "failed"
            report.error = {
                "type": "FixExhausted",
                "message": f"修复 {FIX_MAX_ROUNDS} 轮仍未通过，需升级 L2 协商",
            }
            log(f"  ✗ 修复失败（{FIX_MAX_ROUNDS} 轮用尽）")

    except Exception as e:
        report.status = "failed"
        report.error = {"type": type(e).__name__, "message": str(e)}
        log(f"  ✗ 修复异常：{e}")

    report.end_time = now_iso()
    return report


# ════════════════════════════════════════════════════════════════


def stage_06_deliver(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [06 交付归档] ═══")
    report = StageReport(stage="06-deliver", status="running", start_time=now_iso())

    try:
        workdir = ctx.worktree_path or Path(cfg["claude_workdir"])

        # 汇总
        files_changed_count = 0
        if "02-code" in ctx.reports:
            files_changed_count = ctx.reports["02-code"].output.get("files_changed_count", 0)

        # version.md 追加条目
        version_md = Path(cfg["path"]) / "version.md"
        version_entry = ""
        if version_md.exists() or True:  # 即便不存在也尝试创建
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")
            version_entry = f"""
### pipeline 自动交付 — {timestamp}

**任务**: {ctx.task}
**项目**: {ctx.project}
**变更文件数**: {files_changed_count}

| 阶段 | 状态 |
|------|------|
"""
            for stage_id in sorted(ctx.reports.keys()):
                s = ctx.reports[stage_id]
                version_entry += f"| {stage_id} | {s.status} |\n"

        report.status = "success"
        report.output = {
            "summary": {
                "task": ctx.task,
                "project": ctx.project,
                "lang": ctx.lang,
                "files_changed": files_changed_count,
                "stages_run": list(ctx.reports.keys()),
            },
            "version_md_entry": version_entry,
            "report_dir": str(ctx.report_dir) if ctx.report_dir else "",
        }
        log("  ✓ 交付归档完成")

    except Exception as e:
        report.status = "failed"
        report.error = {"type": type(e).__name__, "message": str(e)}
        log(f"  ✗ 交付归档失败：{e}")

    report.end_time = now_iso()
    return report


# ════════════════════════════════════════════════════════════════
# 编排
# ════════════════════════════════════════════════════════════════


STAGES = [
    ("01", "01-requirement", stage_01_requirement),
    ("02", "02-code", stage_02_code),
    ("03", "03-api-test", stage_03_api_test),
    ("04", "04-e2e", stage_04_e2e),
    ("05", "05-fix", stage_05_fix),
    ("06", "06-deliver", stage_06_deliver),
]


def run_with_retry(stage_fn, ctx, cfg, stage_id: str) -> StageReport:
    """带重试的阶段执行（最多 MAX_RETRIES 次）"""
    last_report = None
    for attempt in range(MAX_RETRIES + 1):
        if attempt > 0:
            log(f"  ↻ 重试 {attempt}/{MAX_RETRIES}")
            time.sleep(RETRY_INTERVAL_SEC)

        report = stage_fn(ctx, cfg)
        report.retry_count = attempt
        last_report = report

        if report.status == "success" or report.status == "skipped":
            return report

        # 委派零产出立即 STOP（不重试）
        if report.error and "零产出" in report.error.get("message", ""):
            log("  ⛔ 委派零产出，立即 STOP")
            return report

    return last_report


def orchestrate(ctx: PipelineContext) -> int:
    if ctx.project not in PROJECTS:
        log(f"❌ 未知项目：{ctx.project}")
        log(f"   可用项目：{', '.join(PROJECTS.keys())}")
        return 1

    cfg = PROJECTS[ctx.project]
    if "lang" not in cfg:
        cfg["lang"] = ctx.lang

    # 创建报告目录
    timestamp = datetime.now().strftime("%Y%m%d-%H%M")
    ctx.report_dir = REPORT_BASE / ctx.project / timestamp
    ctx.report_dir.mkdir(parents=True, exist_ok=True)

    # 创建 worktree（仅在非 dry-run 时）
    if not ctx.dry_run and ctx.from_stage <= "02":
        try:
            worktree_path = Path("/tmp") / f"pipeline-{ctx.project}-{int(time.time())}"
            rc, _, stderr = run_cmd(
                ["git", "worktree", "add", str(worktree_path), "HEAD"],
                cwd=cfg["path"],
            )
            if rc == 0:
                ctx.worktree_path = worktree_path
                log(f"  ✓ 创建 worktree：{worktree_path}")
            else:
                log(f"  ⚠️ worktree 创建失败，使用主目录：{stderr[:200]}")
                ctx.worktree_path = Path(cfg["claude_workdir"])
        except Exception as e:
            log(f"  ⚠️ worktree 异常：{e}")
            ctx.worktree_path = Path(cfg["claude_workdir"])

    log(f"📦 项目：{ctx.project} | 任务：{ctx.task}")
    log(f"📁 报告目录：{ctx.report_dir}")
    log(f"⚙️ 模式：{'dry-run' if ctx.dry_run else 'real'} | {'only-analyze' if ctx.only_analyze else 'full'}")
    log("")

    # 决定从哪个阶段开始
    start_idx = 0
    if ctx.from_stage:
        for i, (num, sid, _) in enumerate(STAGES):
            if sid == ctx.from_stage:
                start_idx = i
                break

    # only-analyze 模式只跑 01
    end_idx = len(STAGES)
    if ctx.only_analyze:
        end_idx = 1

    # 执行
    for i in range(start_idx, end_idx):
        num, stage_id, stage_fn = STAGES[i]

        # 04 在 skip_e2e 时跳过
        if stage_id == "04-e2e" and ctx.skip_e2e:
            log(f"═══ [{num} {stage_id}] ═══")
            log("  ⊘ 跳过（--skip-e2e）")
            report = StageReport(stage=stage_id, status="skipped", start_time=now_iso(), end_time=now_iso())
            report.output = {"reason": "用户指定 --skip-e2e"}
            ctx.reports[stage_id] = report
            write_json(ctx.report_dir / f"{stage_id}.json", report.to_json())
            continue

        report = run_with_retry(stage_fn, ctx, cfg, stage_id)
        ctx.reports[stage_id] = report
        write_json(ctx.report_dir / f"{stage_id}.json", report.to_json())

        # 关键失败立即中止（除 05 修复外）
        if report.status == "failed" and stage_id not in ("05-fix", "06-deliver"):
            if report.error and "零产出" in report.error.get("message", ""):
                log("⛔ 关键失败，pipeline 终止")
                return 2

    # 总结
    log("")
    log("════════════════════════════════════════")
    log("📊 Pipeline 总结")
    log("════════════════════════════════════════")
    for stage_id, report in ctx.reports.items():
        icon = {"success": "✓", "failed": "✗", "skipped": "⊘"}.get(report.status, "?")
        log(f"  {icon} {stage_id}: {report.status} (retry={report.retry_count})")

    # 写最终交付报告
    final = {
        "project": ctx.project,
        "task": ctx.task,
        "lang": ctx.lang,
        "timestamp": now_iso(),
        "stages": {sid: r.to_json() for sid, r in ctx.reports.items()},
        "overall_status": "success" if all(
            r.status in ("success", "skipped") for r in ctx.reports.values()
        ) else "failed",
    }
    write_json(ctx.report_dir / "pipeline-summary.json", final)

    # 清理 worktree
    if ctx.worktree_path and "/tmp/pipeline-" in str(ctx.worktree_path) and not ctx.dry_run:
        try:
            run_cmd(["git", "worktree", "remove", "--force", str(ctx.worktree_path)], cwd=cfg["path"])
            log(f"  ✓ 清理 worktree：{ctx.worktree_path}")
        except Exception as e:
            log(f"  ⚠️ worktree 清理失败：{e}")

    return 0 if final["overall_status"] == "success" else 3


# ════════════════════════════════════════════════════════════════
# CLI
# ════════════════════════════════════════════════════════════════


def main():
    parser = argparse.ArgumentParser(
        description="Hermes Pipeline — 端到端 6 阶段自动化交付流水线",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例：
  %(prog)s --project my-app --task "实现用户登录接口"
  %(prog)s --project my-app --task "..." --skip-e2e
  %(prog)s --project my-app --task "..." --from-stage 03
  %(prog)s --project my-app --task "..." --only-analyze
  %(prog)s --project my-app --task "..." --dry-run
        """,
    )
    parser.add_argument("--project", required=True, help="PROJECTS 中配置的项目名")
    parser.add_argument("--task", required=True, help="自然语言任务描述")
    parser.add_argument("--lang", default="python", help="目标语言（默认 python）")
    parser.add_argument("--skip-e2e", action="store_true", help="跳过 04 页面联调阶段")
    parser.add_argument("--only-analyze", action="store_true", help="只跑 01 需求分析阶段")
    parser.add_argument("--dry-run", action="store_true", help="干跑：不真改代码/不真测试")
    parser.add_argument("--from-stage", default="01-requirement",
                        choices=[s[1] for s in STAGES],
                        help="从指定阶段开始（默认 01-requirement）")
    parser.add_argument("--report-dir", help="自定义报告目录（覆盖默认）")

    args = parser.parse_args()

    ctx = PipelineContext(
        project=args.project,
        task=args.task,
        lang=args.lang,
        skip_e2e=args.skip_e2e,
        dry_run=args.dry_run,
        only_analyze=args.only_analyze,
        from_stage=args.from_stage,
    )

    if args.report_dir:
        ctx.report_dir = Path(args.report_dir)

    try:
        return orchestrate(ctx)
    except KeyboardInterrupt:
        log("\n⚠️ 用户中断")
        return 130


if __name__ == "__main__":
    sys.exit(main())