#!/usr/bin/env python3
"""
Hermes Pipeline — 端到端 6 阶段自动化交付流水线（v4.4）

阶段流转：需求分析 → 代码开发 → 接口测试 → 页面联调（可选）→ 缺陷修复 → 交付归档
每阶段最多 MAX_RETRIES 次重试，间隔 RETRY_INTERVAL_SEC 秒；失败自动升级。

设计要点（v4.4 重构）：
- 阶段注册表 STAGES 驱动编排：新增阶段 = 注册一条 Stage，orchestrate 不变（OCP）
- 状态/阶段全部走 Status 常量与 stage_index() 序号比较，消灭字符串序比较
- CommandRunner 协议注入：测试用 FakeRunner 替换，无需真跑 subprocess（DIP）
- 项目配置外置 config/projects.yaml，load_projects() 纯函数加载，无全局可变状态
- 阶段 02/05 的 Claude Code 调用统一封装到 agent-bridge.sh（不直接 fork claude）
- 阶段 04 页面联调需要 Playwright MCP；缺 MCP 时主动声明未实现，不假装"只检查 URL 可达"

Usage:
    python pipeline.py --project my-app --task "实现用户登录接口"
    python pipeline.py --project my-app --task "..." --skip-e2e
    python pipeline.py --project my-app --task "..." --from-stage 03-api-test
    python pipeline.py --project my-app --task "..." --only-analyze
    python pipeline.py --project my-app --task "..." --dry-run
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Protocol


# ════════════════════════════════════════════════════════════════
# 状态与阶段常量（B4：唯一字面量来源，序列化值保持兼容）
# ════════════════════════════════════════════════════════════════


class Status:
    """StageReport.status 的合法取值。序列化到 JSON 的字符串保持不变。"""

    SUCCESS = "success"
    FAILED = "failed"
    SKIPPED = "skipped"
    RUNNING = "running"

    #: 视为"阶段通过，可继续"的终态
    OK = frozenset({SUCCESS, SKIPPED})


# ════════════════════════════════════════════════════════════════
# 全局配置（不可变常量）
# ════════════════════════════════════════════════════════════════

# 自定位项目根：脚本部署在 <项目>/.hermes/scripts/，parent.parent 即 .hermes/ 根
REPO_ROOT = Path(__file__).resolve().parent.parent
HERMES_HOME = Path(os.environ.get("HERMES_HOME", REPO_ROOT))
AGENT_BRIDGE_SH = HERMES_HOME / "scripts" / "agent-bridge.sh"
REPORT_BASE = Path.home() / ".workbuddy" / "pipeline-reports"

MAX_RETRIES = 2
RETRY_INTERVAL_SEC = 5
FIX_MAX_ROUNDS = 2
# 注意（批次 B 起）：这里的重试只覆盖 pipeline **自身阶段**的重跑。
# worker（编码代理）侧的连续失败熔断由平台看板控制（--max-retries / dispatcher
# failure_limit 默认 2；--max-runtime 超时重排队），本脚本不得再叠加计数。
DEFAULT_MAX_TURNS_CODE = 15
DEFAULT_MAX_TURNS_FIX = 10
DEFAULT_ROLE_CODE = "backend-developer"

# 阶段 02/05 委派零产出时的错误标记（orchestrate 据此立即 STOP）
ZERO_OUTPUT_MARKER = "零产出"


# ════════════════════════════════════════════════════════════════
# 项目配置加载（C2/E3：外置 YAML，纯函数，无全局可变状态）
# ════════════════════════════════════════════════════════════════


def _parse_scalar(raw: str) -> Any:
    """解析 YAML 标量子集：bool / int / 去引号字符串。"""
    v = raw.strip()
    if not v:
        return ""
    if v[0] in "\"'" and v[-1:] == v[0]:
        return v[1:-1]
    low = v.lower()
    if low in ("true", "yes"):
        return True
    if low in ("false", "no"):
        return False
    if low in ("null", "~"):
        return None
    try:
        return int(v)
    except ValueError:
        return v


def _parse_simple_yaml(text: str) -> dict[str, dict[str, Any]]:
    """解析受控的两层 YAML 映射（top: 换行 -> key: value），零依赖兜底。

    仅支持本仓库 config/projects.yaml 使用的子集；复杂结构请安装 pyyaml。
    """
    result: dict[str, dict[str, Any]] = {}
    current: dict[str, Any] | None = None
    for raw_line in text.splitlines():
        line = raw_line.split(" #", 1)[0].rstrip()  # 去行尾注释
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith((" ", "\t")):
            key = line.split(":", 1)[0].strip()
            current = {}
            result[key] = current
        elif current is not None and ":" in line:
            key, _, value = line.strip().partition(":")
            current[key.strip()] = _parse_scalar(value)
    return result


def load_projects(config_path: Path | None = None) -> dict[str, dict[str, Any]]:
    """加载项目注册表。

    显式传入 config_path 时具有权威性：只加载该文件，不存在则返回空 dict
    （调用方应视为配置错误，而非静默回退）。
    未显式指定时按顺序搜索：环境变量 → 部署目录 → 仓库内置。

    纯函数：每次调用返回新 dict，调用方修改不污染任何全局状态。
    """
    if config_path is not None:
        candidates = [config_path]
    else:
        candidates = [
            Path(os.environ["HERMES_PROJECTS_YAML"]) if os.environ.get("HERMES_PROJECTS_YAML") else None,
            HERMES_HOME / "config" / "projects.yaml",
            REPO_ROOT / "config" / "projects.yaml",
        ]
    for path in candidates:
        if path and path.exists():
            text = path.read_text(encoding="utf-8")
            try:
                import yaml  # type: ignore

                data = yaml.safe_load(text)
            except ImportError:
                data = _parse_simple_yaml(text)
            return {k: (v or {}) for k, v in (data or {}).items()}
    return {}


# ════════════════════════════════════════════════════════════════
# 命令执行抽象（D1：依赖注入接缝）
# ════════════════════════════════════════════════════════════════


@dataclass
class CmdResult:
    rc: int
    stdout: str = ""
    stderr: str = ""


class CommandRunner(Protocol):
    """命令执行协议。生产用 SubprocessRunner，测试用 FakeRunner。"""

    def run(self, cmd: list[str], cwd: Path | None = None, timeout: int = 300) -> CmdResult:
        ...


class SubprocessRunner:
    """真实 subprocess 执行器。"""

    def run(self, cmd: list[str], cwd: Path | None = None, timeout: int = 300) -> CmdResult:
        try:
            result = subprocess.run(
                cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
            )
            return CmdResult(result.returncode, result.stdout, result.stderr)
        except subprocess.TimeoutExpired:
            return CmdResult(-1, "", f"Timeout after {timeout}s")
        except FileNotFoundError as e:
            return CmdResult(-1, "", str(e))


# ════════════════════════════════════════════════════════════════
# 数据结构
# ════════════════════════════════════════════════════════════════


@dataclass
class StageReport:
    stage: str
    status: str  # 取值见 Status
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
    path_override: str = ""  # --path 传入：覆盖项目配置的 path/workdir
    runner: CommandRunner = field(default_factory=SubprocessRunner)  # D1 注入点
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


def git_diff_stat(runner: CommandRunner, workdir: Path) -> tuple[int, str]:
    """返回 (变更文件数, diff_stat 输出)"""
    r = runner.run(["git", "diff", "--stat", "HEAD"], cwd=workdir)
    if r.rc != 0:
        return 0, ""
    files = [line for line in r.stdout.splitlines() if "|" in line]
    return len(files), r.stdout.strip()


def invoke_agent_bridge(
    runner: CommandRunner, role: str, task: str, workdir: Path, max_turns: int,
) -> CmdResult:
    """通过 agent-bridge.sh 委派任务（统一封装，避免直接调用 claude -p）"""
    if not AGENT_BRIDGE_SH.exists():
        return CmdResult(-1, "", f"agent-bridge.sh 不存在：{AGENT_BRIDGE_SH}")
    cmd = [
        "bash", str(AGENT_BRIDGE_SH), "claude", role, task,
        "--workdir", str(workdir),
        "--max-turns", str(max_turns),
    ]
    return runner.run(cmd, cwd=workdir, timeout=600)


def resolve_test_cmd(cfg: dict) -> list[str] | None:
    """从项目配置取测试命令（api_test_cmd 优先），返回 argv 列表。"""
    test_cmd = cfg.get("api_test_cmd") or cfg.get("test_cmd")
    if not test_cmd:
        return None
    return test_cmd.split() if isinstance(test_cmd, str) else list(test_cmd)


def _fail(report: StageReport, err_type: str, message: str) -> StageReport:
    report.status = Status.FAILED
    report.error = {"type": err_type, "message": message}
    return report


# ════════════════════════════════════════════════════════════════
# 阶段实现
# ════════════════════════════════════════════════════════════════


def stage_01_requirement(ctx: PipelineContext, cfg: dict) -> StageReport:
    """阶段 01：建立任务入口契约。深度语义分析由 Hermes（LLM）在派发前完成。"""
    log("═══ [01 需求分析] ═══")
    report = StageReport(stage="01-requirement", status=Status.RUNNING, start_time=now_iso())
    report.input = {"task": ctx.task, "project_path": cfg["path"]}

    try:
        if not Path(cfg["path"]).exists():
            raise FileNotFoundError(f"项目路径不存在：{cfg['path']}")

        report.status = Status.SUCCESS
        report.output = {
            "task": ctx.task,
            "project": ctx.project,
            "language": ctx.lang,
            "note": "深度分析由 Hermes LLM 在派发前完成；本阶段仅落盘入口契约",
        }
        log("  ✓ 需求契约已建立")
    except Exception as e:
        _fail(report, type(e).__name__, str(e))
        log(f"  ✗ 需求契约建立失败：{e}")

    report.end_time = now_iso()
    return report


def stage_02_code(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [02 代码开发] ═══")
    report = StageReport(stage="02-code", status=Status.RUNNING, start_time=now_iso())
    report.input = {"task": ctx.task, "workdir": str(ctx.worktree_path)}

    if ctx.dry_run:
        log("  [dry-run] 跳过实际编码")
        report.status = Status.SUCCESS
        report.output = {"dry_run": True}
        report.end_time = now_iso()
        return report

    try:
        workdir = ctx.worktree_path or Path(cfg["workdir"])
        workdir.mkdir(parents=True, exist_ok=True)

        r = invoke_agent_bridge(ctx.runner, DEFAULT_ROLE_CODE, ctx.task, workdir, DEFAULT_MAX_TURNS_CODE)
        if r.rc != 0:
            raise RuntimeError(f"agent-bridge 退出码 {r.rc}: {r.stderr[:500]}")

        diff_count, diff_stat = git_diff_stat(ctx.runner, workdir)
        if diff_count == 0:
            raise RuntimeError(f"委派{ZERO_OUTPUT_MARKER}！git diff 为空。\nSTOP：转手动 patch，不重试。")

        report.status = Status.SUCCESS
        report.output = {
            "files_changed_count": diff_count,
            "diff_stat": diff_stat,
            "stdout_preview": r.stdout[:500],
        }
        log(f"  ✓ 代码开发完成（{diff_count} 个文件变更）")
    except Exception as e:
        _fail(report, type(e).__name__, str(e))
        log(f"  ✗ 代码开发失败：{e}")

    report.end_time = now_iso()
    return report


def stage_03_api_test(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [03 接口测试] ═══")
    report = StageReport(stage="03-api-test", status=Status.RUNNING, start_time=now_iso())
    report.input = {"test_cmd": cfg.get("api_test_cmd")}

    if ctx.dry_run:
        report.status = Status.SUCCESS
        report.output = {"dry_run": True}
        report.end_time = now_iso()
        log("  [dry-run] 跳过接口测试")
        return report

    try:
        workdir = ctx.worktree_path or Path(cfg["workdir"])
        cmd_parts = resolve_test_cmd(cfg)
        if not cmd_parts:
            raise ValueError("项目配置缺少 test_cmd 或 api_test_cmd")

        r = ctx.runner.run(cmd_parts, cwd=workdir, timeout=300)
        report.output = {
            "returncode": r.rc,
            "passed": r.rc == 0,
            "stdout_tail": r.stdout[-500:] if r.stdout else "",
            "stderr_tail": r.stderr[-300:] if r.stderr else "",
        }
        if r.rc == 0:
            report.status = Status.SUCCESS
            log("  ✓ 接口测试通过")
        else:
            _fail(report, "TestFailure", f"测试退出码 {r.rc}")
            log(f"  ✗ 接口测试失败（退出码 {r.rc}）")
    except Exception as e:
        _fail(report, type(e).__name__, str(e))
        log(f"  ✗ 接口测试异常：{e}")

    report.end_time = now_iso()
    return report


def stage_04_e2e(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [04 页面联调] ═══")
    report = StageReport(stage="04-e2e", status=Status.RUNNING, start_time=now_iso())

    if ctx.skip_e2e or cfg.get("skip_e2e"):
        reason = "用户指定 --skip-e2e" if ctx.skip_e2e else "项目配置 skip_e2e=True"
        report.status = Status.SKIPPED
        report.output = {"reason": reason}
        report.end_time = now_iso()
        log(f"  ⊘ 跳过页面联调（{reason}）")
        return report

    if ctx.dry_run:
        report.status = Status.SUCCESS
        report.output = {"dry_run": True}
        report.end_time = now_iso()
        log("  [dry-run] 跳过页面联调")
        return report

    # 真实实现需要 Playwright MCP 客户端接入；当前未实现，主动声明避免假装通过
    _fail(
        report, "NotImplemented",
        "页面联调需要 Playwright MCP 客户端；当前 pipeline 未集成，需手动执行或安装 MCP",
    )
    report.output = {"frontend_url": cfg.get("frontend_url", "")}
    log("  ⚠ 页面联调未实现（需 Playwright MCP）—— 状态置 failed，请手动验证")

    report.end_time = now_iso()
    return report


def stage_05_fix(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [05 缺陷修复] ═══")
    report = StageReport(stage="05-fix", status=Status.RUNNING, start_time=now_iso())

    if ctx.dry_run:
        report.status = Status.SUCCESS
        report.output = {"dry_run": True}
        report.end_time = now_iso()
        log("  [dry-run] 跳过修复")
        return report

    try:
        workdir = ctx.worktree_path or Path(cfg["workdir"])

        bugs = [
            {"stage": sid, "error": s.error}
            for sid in ("03-api-test", "04-e2e")
            if (s := ctx.reports.get(sid)) and s.status == Status.FAILED
        ]
        if not bugs:
            report.status = Status.SUCCESS
            report.output = {"reason": "无失败用例，无需修复"}
            log("  ✓ 无失败用例")
            report.end_time = now_iso()
            return report

        bugs_md = workdir / "BUGS.md"
        bugs_md.write_text(
            "# 失败用例汇总\n\n" + "\n".join(
                f"## {b['stage']}\n```json\n{json.dumps(b['error'], ensure_ascii=False, indent=2)}\n```\n"
                for b in bugs
            ),
            encoding="utf-8",
        )

        for round_idx in range(1, FIX_MAX_ROUNDS + 1):
            log(f"  修复轮次 {round_idx}/{FIX_MAX_ROUNDS}")
            r = invoke_agent_bridge(
                ctx.runner, DEFAULT_ROLE_CODE,
                "读 BUGS.md 并修复。修复后跑测试确认通过。",
                workdir, DEFAULT_MAX_TURNS_FIX,
            )
            if r.rc != 0:
                log(f"  agent-bridge 退出码 {r.rc}")
                continue

            diff_count, _ = git_diff_stat(ctx.runner, workdir)
            if diff_count == 0:
                log("  修复无产出，停止")
                break

            cmd_parts = resolve_test_cmd(cfg)
            if cmd_parts:
                r_test = ctx.runner.run(cmd_parts, cwd=workdir, timeout=300)
                if r_test.rc == 0:
                    report.status = Status.SUCCESS
                    report.output = {"rounds_used": round_idx, "fixed": True, "diff_count": diff_count}
                    log(f"  ✓ 修复成功（{round_idx} 轮）")
                    break
        else:
            _fail(report, "FixExhausted", f"修复 {FIX_MAX_ROUNDS} 轮仍未通过，需升级 L2 协商")
            log(f"  ✗ 修复失败（{FIX_MAX_ROUNDS} 轮用尽）")

    except Exception as e:
        _fail(report, type(e).__name__, str(e))
        log(f"  ✗ 修复异常：{e}")

    report.end_time = now_iso()
    return report


def stage_06_deliver(ctx: PipelineContext, cfg: dict) -> StageReport:
    log("═══ [06 交付归档] ═══")
    report = StageReport(stage="06-deliver", status=Status.RUNNING, start_time=now_iso())

    try:
        code_report = ctx.reports.get("02-code")
        files_changed = code_report.output.get("files_changed_count", 0) if code_report else 0

        report.status = Status.SUCCESS
        report.output = {
            "summary": {
                "task": ctx.task,
                "project": ctx.project,
                "lang": ctx.lang,
                "files_changed": files_changed,
                "stages_run": list(ctx.reports.keys()),
            },
            "report_dir": str(ctx.report_dir) if ctx.report_dir else "",
        }
        log("  ✓ 交付归档完成")
    except Exception as e:
        _fail(report, type(e).__name__, str(e))
        log(f"  ✗ 交付归档异常：{e}")

    report.end_time = now_iso()
    return report


# ════════════════════════════════════════════════════════════════
# 阶段注册表（C4：orchestrate 只驱动本表，新增阶段 = 加一行）
# ════════════════════════════════════════════════════════════════


@dataclass(frozen=True)
class Stage:
    num: str
    stage_id: str
    fn: Callable[[PipelineContext, dict], StageReport]
    #: 失败含零产出标记时是否中止整个 pipeline（05 修复/06 交付不中止）
    abort_on_zero_output: bool = True


STAGES: list[Stage] = [
    Stage("01", "01-requirement", stage_01_requirement),
    Stage("02", "02-code", stage_02_code),
    Stage("03", "03-api-test", stage_03_api_test),
    Stage("04", "04-e2e", stage_04_e2e),
    Stage("05", "05-fix", stage_05_fix, abort_on_zero_output=False),
    Stage("06", "06-deliver", stage_06_deliver, abort_on_zero_output=False),
]

STAGE_IDS: list[str] = [s.stage_id for s in STAGES]


def stage_index(stage_id: str) -> int:
    """阶段序号比较的唯一入口（替代字符串序比较）。"""
    try:
        return STAGE_IDS.index(stage_id)
    except ValueError:
        return -1


# ════════════════════════════════════════════════════════════════
# 编排（B3：拆分为 配置解析 / worktree / 单阶段执行 / 总结 四段）
# ════════════════════════════════════════════════════════════════


def resolve_config(ctx: PipelineContext, projects: dict) -> dict | None:
    """解析项目配置；未知项目返回 None。返回新 dict，不改调用方数据。"""
    if ctx.project not in projects:
        log(f"❌ 未知项目：{ctx.project}")
        log(f"   可用项目：{', '.join(projects.keys()) or '(projects.yaml 为空)'}")
        return None
    cfg = dict(projects[ctx.project])
    cfg.setdefault("lang", ctx.lang)
    cfg.setdefault("workdir", cfg.get("path", ""))
    if ctx.path_override:
        cfg["path"] = ctx.path_override
        cfg["workdir"] = ctx.path_override
    return cfg


def setup_worktree(ctx: PipelineContext, cfg: dict) -> None:
    """为 02 代码开发创建 git worktree；失败降级到主目录。"""
    try:
        worktree_path = Path("/tmp") / f"pipeline-{ctx.project}-{int(time.time())}"
        r = ctx.runner.run(
            ["git", "worktree", "add", str(worktree_path), "HEAD"],
            cwd=cfg["path"],
        )
        if r.rc == 0:
            ctx.worktree_path = worktree_path
            log(f"  ✓ 创建 worktree：{worktree_path}")
        else:
            log(f"  ⚠️ worktree 创建失败，使用主目录：{r.stderr[:200]}")
            ctx.worktree_path = Path(cfg["workdir"])
    except Exception as e:
        log(f"  ⚠️ worktree 异常：{e}")
        ctx.worktree_path = Path(cfg["workdir"])


def run_stage_with_retry(ctx: PipelineContext, cfg: dict, stage: Stage) -> StageReport:
    """执行单阶段（含重试与零产出 STOP），并落盘阶段报告。"""
    last: StageReport | None = None
    for attempt in range(MAX_RETRIES + 1):
        if attempt > 0:
            log(f"  ↻ 重试 {attempt}/{MAX_RETRIES}")
            time.sleep(RETRY_INTERVAL_SEC)

        r = stage.fn(ctx, cfg)
        r.retry_count = attempt
        last = r

        if r.status in Status.OK:
            break
        if r.error and ZERO_OUTPUT_MARKER in r.error.get("message", ""):
            log("  ⛔ 委派零产出，立即 STOP")
            break

    if last is None:  # 理论不可达，防御兜底
        last = StageReport(stage=stage.stage_id, status=Status.FAILED, end_time=now_iso())

    ctx.reports[stage.stage_id] = last
    write_json(ctx.report_dir / f"{stage.stage_id}.json", last.to_json())
    return last


def cleanup_worktree(ctx: PipelineContext, cfg: dict) -> None:
    if not (ctx.worktree_path and "/tmp/pipeline-" in str(ctx.worktree_path) and not ctx.dry_run):
        return
    try:
        ctx.runner.run(
            ["git", "worktree", "remove", "--force", str(ctx.worktree_path)],
            cwd=cfg["path"],
        )
        log(f"  ✓ 清理 worktree：{ctx.worktree_path}")
    except Exception as e:
        log(f"  ⚠️ worktree 清理失败：{e}")


def summarize(ctx: PipelineContext) -> int:
    """输出总结并返回退出码。"""
    log("")
    log("════════════════════════════════════════")
    log("📊 Pipeline 总结")
    log("════════════════════════════════════════")
    icons = {Status.SUCCESS: "✓", Status.FAILED: "✗", Status.SKIPPED: "⊘"}
    for stage_id, r in ctx.reports.items():
        log(f"  {icons.get(r.status, '?')} {stage_id}: {r.status} (retry={r.retry_count})")

    overall = (
        Status.SUCCESS
        if all(r.status in Status.OK for r in ctx.reports.values())
        else Status.FAILED
    )
    write_json(ctx.report_dir / "pipeline-summary.json", {
        "project": ctx.project,
        "task": ctx.task,
        "lang": ctx.lang,
        "timestamp": now_iso(),
        "stages": {sid: r.to_json() for sid, r in ctx.reports.items()},
        "overall_status": overall,
    })
    return 0 if overall == Status.SUCCESS else 3


def orchestrate(ctx: PipelineContext, projects: dict | None = None) -> int:
    """通用驱动循环：只依赖 STAGES 注册表，不认识任何具体阶段。"""
    if projects is None:
        projects = load_projects()

    cfg = resolve_config(ctx, projects)
    if cfg is None:
        return 1

    timestamp = datetime.now().strftime("%Y%m%d-%H%M")
    if ctx.report_dir is None:
        ctx.report_dir = REPORT_BASE / ctx.project / timestamp
    ctx.report_dir.mkdir(parents=True, exist_ok=True)

    start_idx = stage_index(ctx.from_stage)
    if start_idx < 0:
        log(f"❌ 未知起始阶段：{ctx.from_stage}（可选：{', '.join(STAGE_IDS)}）")
        return 1

    # worktree 只服务 02 代码开发：起点在 02 之前（含）才创建
    if not ctx.dry_run and start_idx <= stage_index("02-code"):
        setup_worktree(ctx, cfg)

    log(f"📦 项目：{ctx.project} | 任务：{ctx.task}")
    log(f"📁 报告目录：{ctx.report_dir}")
    log(f"⚙️ 模式：{'dry-run' if ctx.dry_run else 'real'} | {'only-analyze' if ctx.only_analyze else 'full'}")
    log("")

    end_idx = stage_index("01-requirement") + 1 if ctx.only_analyze else len(STAGES)

    for stage in STAGES[start_idx:end_idx]:
        last = run_stage_with_retry(ctx, cfg, stage)

        if (
            last.status == Status.FAILED
            and stage.abort_on_zero_output
            and last.error
            and ZERO_OUTPUT_MARKER in last.error.get("message", "")
        ):
            log("⛔ 关键失败，pipeline 终止")
            return 2

    exit_code = summarize(ctx)
    cleanup_worktree(ctx, cfg)
    return exit_code


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
  %(prog)s --project my-app --task "..." --from-stage 03-api-test
  %(prog)s --project my-app --task "..." --only-analyze
  %(prog)s --project my-app --task "..." --dry-run
        """,
    )
    parser.add_argument("--project", required=True, help="projects.yaml 中配置的项目名")
    parser.add_argument("--path", help="覆盖项目路径（免改配置的临时指向）")
    parser.add_argument("--projects-config", help="显式指定 projects.yaml 路径")
    parser.add_argument("--task", required=True, help="自然语言任务描述")
    parser.add_argument("--lang", default="python", help="目标语言（默认 python）")
    parser.add_argument("--skip-e2e", action="store_true", help="跳过 04 页面联调阶段")
    parser.add_argument("--only-analyze", action="store_true", help="只跑 01 需求分析阶段")
    parser.add_argument("--dry-run", action="store_true", help="干跑：不真改代码/不真测试")
    parser.add_argument(
        "--from-stage", default="01-requirement",
        choices=STAGE_IDS,
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
        path_override=args.path or "",
    )
    if args.report_dir:
        ctx.report_dir = Path(args.report_dir)

    projects = load_projects(Path(args.projects_config) if args.projects_config else None)

    try:
        return orchestrate(ctx, projects)
    except KeyboardInterrupt:
        log("\n⚠️ 用户中断")
        return 130


if __name__ == "__main__":
    sys.exit(main())
