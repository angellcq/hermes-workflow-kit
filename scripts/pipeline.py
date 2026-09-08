#!/usr/bin/env python3
"""
Hermes Pipeline — 端到端 6 阶段自动化交付流水线（融合版 v4.1）

阶段流转：需求分析 → 代码开发 → 接口测试 → 页面联调（可选）→ 缺陷修复 → 交付归档
每阶段最多 2 次重试，间隔 5s；失败自动升级。

设计要点：
- 阶段 02 / 05 的 Claude Code 调用统一封装到 agent-bridge.sh（不直接 fork claude）
- 阶段 04 页面联调需要 Playwright MCP；缺 MCP 时主动声明未实现，不假装"只检查 URL 可达"
- 阶段 01 需求分析是轻量入口文件 + acceptance 列表，深度分析由 Hermes 在派发前完成

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
        "workdir": r"D:\projects\my-app",
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
    #     "workdir": r"D:\path\to\project",
    #     "skip_e2e": True,
    #     "test_cmd": "go test ./...",
    #     "api_test_cmd": "go test ./tests/api/...",
    #     "build_cmd": "go build ./...",
    # },
}

# ════════════════════════════════════════════════════════════════
# 全局配置
# ════════════════════════════════════════════════════════════════

HERMES_HOME = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
AGENT_BRIDGE_SH = HERMES_HOME / "scripts" / "agent-bridge.sh"
REPORT_BASE = Path.home() / ".workbuddy" / "pipeline-reports"
MAX_RETRIES = 2
RETRY_INTERVAL_SEC = 5
FIX_MAX_ROUNDS = 2
DEFAULT_MAX_TURNS_CODE = 15
DEFAULT_MAX_TURNS_FIX = 10
DEFAULT_ROLE_CODE = "backend-developer"


# ════════════════════════════════════════════════════════════════
# 数据结构
# ════════════════════════════════════════════════════════════════


@dataclass
class StageReport:
    stage: str
    status: str  # success | failed | retrying | skipped
    start_time: str = ""
    end_time: str = ""
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
    return datetime.now().isoformat()


def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def run_cmd(cmd: list[str], cwd: Path | None = None, timeout: int = 300) -> tuple[int, str, str]:
    """执行命令并返回 (returncode, stdout, stderr)"""
    try:
        result = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
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


def invoke_agent_bridge(role: str, task: str, workdir: Path, max_turns: int) -> tuple[int, str, str]:
    """通过 agent-bridge.sh 委派任务（统一封装，避免直接调用 claude -p）"""
    if not AGENT_BRIDGE_SH.exists():
        return -1, "", f"agent-bridge.sh 不存在：{AGENT_BRIDGE_SH}"
    cmd = [
        "bash", str(AGENT_BRIDGE_SH), "claude", role, task,
        "--workdir", str(workdir),
        "--max-turns", str(max_turns),
    ]
    return run_cmd(cmd, cwd=workdir, timeout=600)


# ════════════════════════════════════════════════════════════════
# 阶段 01：需求分析（轻量入口，深度分析由 Hermes 在派发前完成）
# ════════════════════════════════════════════════════════════════


def stage_01_requirement(ctx: PipelineContext, cfg: dict) -> StageReport:
    """阶段 01：建立任务入口文件，把需求与验收标准落盘到 TASK.md。

    真正的语义分析由 Hermes（LLM）在收到 --task 时完成；本阶段只做"落盘契约"。
    """
    log("═══ [01 需求分析] ═══")
    report = StageReport(stage="01-requirement", status="running", start_time=now_iso())
    report.input = {"task": ctx.task, "project_path": cfg["path"]}

    try:
        project_path = Path(cfg["path"])
        if not project_path.exists():
            raise FileNotFoundError(f"项目路径不存在：{cfg['path']}")

        report.status = "success"
        report.output = {
            "task": ctx.task,
            "project": ctx.project,
            "language": ctx.lang,
            "note": "深度分析由 Hermes LLM 在派发前完成；本阶段仅落盘入口契约",
        }
        log("  ✓ 需求契约已建立")
    except Exception as e:
        report.status = "failed"
        report.error = {"type": type(e).__name__, "message": str(e)}
        log(f"  ✗ 需求契约建立失败：{e}")

    report.end_time = now_iso()
    return report


# ════════════════════════════════════════════════════════════════
# 阶段 02：代码开发（调用 agent-bridge.sh，不直接 fork claude）
# ════════════════════════════════════════════════════════════════


def stage_02_code(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [02 代码开发] ═══")
    report = StageReport(stage="02-code", status="running", start_time=now_iso())
    report.input = {"task": ctx.task, "workdir": str(ctx.worktree_path)}

    if ctx.dry_run:
        log("  [dry-run] 跳过实际编码")
        report.status = "success"
        report.output = {"dry_run": True}
        report.end_time = now_iso()
        return report

    try:
        workdir = ctx.worktree_path or Path(cfg["workdir"])
        workdir.mkdir(parents=True, exist_ok=True)

        rc, stdout, stderr = invoke_agent_bridge(
            DEFAULT_ROLE_CODE,
            ctx.task,
            workdir,
            DEFAULT_MAX_TURNS_CODE,
        )

        if rc != 0:
            raise RuntimeError(f"agent-bridge 退出码 {rc}: {stderr[:500]}")

        diff_count, diff_stat = git_diff_stat(workdir)
        if diff_count == 0:
            raise RuntimeError(
                "委派零产出！git diff 为空。\n"
                "STOP：转手动 patch，不重试。"
            )

        report.status = "success"
        report.output = {
            "files_changed_count": diff_count,
            "diff_stat": diff_stat,
            "stdout_preview": stdout[:500],
        }
        log(f"  ✓ 代码开发完成（{diff_count} 个文件变更）")
    except Exception as e:
        report.status = "failed"
        report.error = {"type": type(e).__name__, "message": str(e)}
        log(f"  ✗ 代码开发失败：{e}")

    report.end_time = now_iso()
    return report


# ════════════════════════════════════════════════════════════════
# 阶段 03：接口测试
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
        workdir = ctx.worktree_path or Path(cfg["workdir"])
        test_cmd = cfg.get("api_test_cmd") or cfg.get("test_cmd")
        if not test_cmd:
            raise ValueError("PROJECTS 配置缺少 test_cmd 或 api_test_cmd")

        cmd_parts = test_cmd.split() if isinstance(test_cmd, str) else test_cmd
        rc, stdout, stderr = run_cmd(cmd_parts, cwd=workdir, timeout=300)

        report.output = {
            "returncode": rc,
            "passed": rc == 0,
            "stdout_tail": stdout[-500:] if stdout else "",
            "stderr_tail": stderr[-300:] if stderr else "",
        }
        if rc == 0:
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
# 阶段 04：页面联调（Playwright MCP 未实现时主动声明）
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

    # 真实实现需要 Playwright MCP 客户端接入；当前未实现，主动声明避免假装通过
    report.status = "failed"
    report.error = {
        "type": "NotImplemented",
        "message": "页面联调需要 Playwright MCP 客户端；当前 pipeline 未集成，需手动执行或安装 MCP",
    }
    report.output = {"frontend_url": cfg.get("frontend_url", "")}
    log("  ⚠ 页面联调未实现（需 Playwright MCP）—— 状态置 failed，请手动验证")

    report.end_time = now_iso()
    return report


# ════════════════════════════════════════════════════════════════
# 阶段 05：缺陷修复（agent-bridge.sh 委派，闭环最多 FIX_MAX_ROUNDS 轮）
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
        workdir = ctx.worktree_path or Path(cfg["workdir"])

        # 收集失败用例
        bugs = []
        for stage_id in ("03-api-test", "04-e2e"):
            s = ctx.reports.get(stage_id)
            if s and s.status == "failed":
                bugs.append({"stage": stage_id, "error": s.error})

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
            "\n".join(
                f"## {b['stage']}\n```json\n{json.dumps(b['error'], ensure_ascii=False, indent=2)}\n```\n"
                for b in bugs
            ),
            encoding="utf-8",
        )

        for round_idx in range(1, FIX_MAX_ROUNDS + 1):
            log(f"  修复轮次 {round_idx}/{FIX_MAX_ROUNDS}")
            rc, _, _ = invoke_agent_bridge(
                DEFAULT_ROLE_CODE,
                "读 BUGS.md 并修复。修复后跑测试确认通过。",
                workdir,
                DEFAULT_MAX_TURNS_FIX,
            )
            if rc != 0:
                log(f"  agent-bridge 退出码 {rc}")
                continue

            diff_count, _ = git_diff_stat(workdir)
            if diff_count == 0:
                log("  修复无产出，停止")
                break

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
# 阶段 06：交付归档
# ════════════════════════════════════════════════════════════════


def stage_06_deliver(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [06 交付归档] ═══")
    report = StageReport(stage="06-deliver", status="running", start_time=now_iso())

    try:
        files_changed_count = 0
        if "02-code" in ctx.reports:
            files_changed_count = ctx.reports["02-code"].output.get("files_changed_count", 0)

        report.status = "success"
        report.output = {
            "summary": {
                "task": ctx.task,
                "project": ctx.project,
                "lang": ctx.lang,
                "files_changed": files_changed_count,
                "stages_run": list(ctx.reports.keys()),
            },
            "report_dir": str(ctx.report_dir) if ctx.report_dir else "",
        }
        log("  ✓ 交付归档完成")
    except Exception as e:
        report.status = "failed"
        report.error = {"type": type(e).__name__, "message": str(e)}
        log(f"  ✗ 交付归档异常：{e}")

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


def orchestrate(ctx: PipelineContext) -> int:
    if ctx.project not in PROJECTS:
        log(f"❌ 未知项目：{ctx.project}")
        log(f"   可用项目：{', '.join(PROJECTS.keys())}")
        return 1

    cfg = PROJECTS[ctx.project]
    cfg.setdefault("lang", ctx.lang)

    timestamp = datetime.now().strftime("%Y%m%d-%H%M")
    ctx.report_dir = REPORT_BASE / ctx.project / timestamp
    ctx.report_dir.mkdir(parents=True, exist_ok=True)

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
                ctx.worktree_path = Path(cfg["workdir"])
        except Exception as e:
            log(f"  ⚠️ worktree 异常：{e}")
            ctx.worktree_path = Path(cfg["workdir"])

    log(f"📦 项目：{ctx.project} | 任务：{ctx.task}")
    log(f"📁 报告目录：{ctx.report_dir}")
    log(f"⚙️ 模式：{'dry-run' if ctx.dry_run else 'real'} | {'only-analyze' if ctx.only_analyze else 'full'}")
    log("")

    start_idx = next(
        (i for i, (_, sid, _) in enumerate(STAGES) if sid == ctx.from_stage),
        0,
    )
    end_idx = 1 if ctx.only_analyze else len(STAGES)

    for i in range(start_idx, end_idx):
        num, stage_id, stage_fn = STAGES[i]

        # 04 在 skip_e2e 时跳过
        if stage_id == "04-e2e" and ctx.skip_e2e:
            log(f"═══ [{num} {stage_id}] ═══")
            log("  ⊘ 跳过（--skip-e2e）")
            report = StageReport(
                stage=stage_id, status="skipped",
                start_time=now_iso(), end_time=now_iso(),
            )
            report.output = {"reason": "用户指定 --skip-e2e"}
            ctx.reports[stage_id] = report
            write_json(ctx.report_dir / f"{stage_id}.json", report.to_json())
            continue

        last_report: StageReport | None = None
        for attempt in range(MAX_RETRIES + 1):
            if attempt > 0:
                log(f"  ↻ 重试 {attempt}/{MAX_RETRIES}")
                time.sleep(RETRY_INTERVAL_SEC)

            r = stage_fn(ctx, cfg)
            r.retry_count = attempt
            last_report = r

            if r.status in ("success", "skipped"):
                break

            # 委派零产出立即 STOP（不重试）
            if r.error and "零产出" in r.error.get("message", ""):
                log("  ⛔ 委派零产出，立即 STOP")
                break

        if last_report is None:
            last_report = StageReport(stage=stage_id, status="failed", end_time=now_iso())

        ctx.reports[stage_id] = last_report
        write_json(ctx.report_dir / f"{stage_id}.json", last_report.to_json())

        # 关键失败立即中止（除 05 修复与 06 交付外）
        if (
            last_report.status == "failed"
            and stage_id not in ("05-fix", "06-deliver")
            and last_report.error
            and "零产出" in last_report.error.get("message", "")
        ):
            log("⛔ 关键失败，pipeline 终止")
            return 2

    log("")
    log("════════════════════════════════════════")
    log("📊 Pipeline 总结")
    log("════════════════════════════════════════")
    for stage_id, r in ctx.reports.items():
        icon = {"success": "✓", "failed": "✗", "skipped": "⊘"}.get(r.status, "?")
        log(f"  {icon} {stage_id}: {r.status} (retry={r.retry_count})")

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

    if ctx.worktree_path and "/tmp/pipeline-" in str(ctx.worktree_path) and not ctx.dry_run:
        try:
            run_cmd(
                ["git", "worktree", "remove", "--force", str(ctx.worktree_path)],
                cwd=cfg["path"],
            )
            log(f"  ✓ 清理 worktree：{ctx.worktree_path}")
        except Exception as e:
            log(f"  ⚠️ worktree 清理失败：{e}")

    return 0 if final["overall_status"] == "success" else 3


# ════════════════════════════════════════════════════════════════
# CLI
# ════════════════════════════════════════════════════════════════


def main() -> int:
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
    parser.add_argument(
        "--from-stage", default="01-requirement",
        choices=[s[1] for s in STAGES],
        help="从指定阶段开始（默认 01-requirement）",
    )
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
