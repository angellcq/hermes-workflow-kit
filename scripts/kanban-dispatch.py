#!/usr/bin/env python3
"""Hermes Kanban Dispatch — tasks.yaml → 原生看板卡（v4.4.2）

路线 A（拥抱 Hermes 原生能力）的核心桥接件：把「一批任务」直接变成**平台原生看板卡**，
不再由套件自己 fork `claude -p` 并维护 active.json。

三道闸门，任一不过即拒绝派发：
  1. 环境闸门：preflight.sh（hermes CLI / 看板 / 调度器存活 / python / 角色库）
  2. 边界闸门：scope-check（并行任务 files_scope 互斥，重叠即拒发）
  3. 幂等闸门：--idempotency-key 用**语义指纹**（目标+边界+验收），平台语义是
     「已存在同 key 的非归档卡 → 返回既有卡 id，不新建」→ 重复子任务天然去重，
     失败重试/补账天然不双跑

用法：
    python scripts/kanban-dispatch.py --tasks tasks.yaml --dry-run     # 预览命令
    python scripts/kanban-dispatch.py --tasks tasks.yaml              # 真建卡
    python scripts/kanban-dispatch.py --tasks tasks.yaml --json       # 机器可读结果
退出码：0 = 全部成功；1 = 闸门未过；2 = 输入/执行错误
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent


def _load_scope_check():
    """动态加载 scope-check.py（文件名带连字符，不能直接 import）。"""
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "scope_check", SCRIPT_DIR / "scope-check.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules["scope_check"] = module
    spec.loader.exec_module(module)
    return module


def slugify(text: str, fallback: str = "task") -> str:
    """标题 → 分支/工作区用的 kebab slug（fallback 同样规范化，避免出现大写/非法字符）。"""
    def _norm(value: str) -> str:
        return re.sub(r"[^0-9a-zA-Z\u4e00-\u9fff]+", "-", value).strip("-").lower()

    s = _norm(text)[:40].strip("-")
    if not s:
        s = _norm(fallback)[:40].strip("-")
    return s or "task"


def preflight(require_dispatcher: bool) -> tuple[int, str]:
    """跑 preflight.sh，返回 (退出码, 输出)。"""
    script = SCRIPT_DIR / "preflight.sh"
    if not script.is_file():
        return 0, "（未找到 preflight.sh，跳过环境闸门）"
    cmd = ["bash", str(script), "--quiet"]
    if require_dispatcher:
        cmd.append("--require-dispatcher")
    # errors="replace"：Windows 上子进程输出可能混入 GBK 字节，严格 utf-8 解码会抛
    # UnicodeDecodeError（读线程崩掉并丢输出）
    proc = subprocess.run(cmd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    return proc.returncode, (proc.stdout or proc.stderr).strip()


def build_create_cmd(
    task: Any,
    fingerprint: str,
    board: str | None,
    workspace: str | None,
    branch: str | None,
    assignee: str | None,
    max_retries: int | None = None,
    max_runtime: str | None = None,
    completion_contract: str | None = None,
    skills: list[str] | None = None,
) -> list[str]:
    body = (
        f"来源: {getattr(task, 'source', 'tasks.yaml')} | "
        f"files_scope: {', '.join(task.files_scope) or '(未声明)'} | "
        f"semantic_hash: {fingerprint}"
    )
    cmd = ["hermes", "kanban"]
    if board:
        cmd += ["--board", board]
    cmd += [
        "create",
        f"{task.task_id}: {task.goal or task.task_id}",
        "--body",
        body,
        "--idempotency-key",
        fingerprint,
    ]
    if assignee:
        cmd += ["--assignee", assignee]
    if workspace:
        cmd += ["--workspace", workspace]
    if branch:
        cmd += ["--branch", f"{branch}/{slugify(task.goal, task.task_id)}"]
    # 平台侧的熔断/超时/完成契约：一律透传，套件不持有自己的重试计数
    if max_retries is not None:
        cmd += ["--max-retries", str(max_retries)]
    if max_runtime:
        cmd += ["--max-runtime", max_runtime]
    if completion_contract:
        cmd += ["--completion-contract", completion_contract]
    for skill in skills or []:
        cmd += ["--skill", skill]
    cmd.append("--json")
    return cmd


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="kanban-dispatch.py",
        description="把 tasks.yaml 批量转为原生看板卡（含边界/幂等/环境三闸门）",
    )
    parser.add_argument("--tasks", required=True, help="tasks.yaml（agent-bridge 格式）")
    parser.add_argument("--dry-run", action="store_true", help="只打印将执行的命令")
    parser.add_argument("--json", action="store_true", help="机器可读输出")
    parser.add_argument("--board", help="看板 slug（默认使用平台当前板）")
    parser.add_argument("--assignee", help="指定 worker profile（默认不指定，交人/调度器）")
    parser.add_argument(
        "--workspace",
        help="工作区类型（worktree / scratch / dir:<绝对路径>）。"
        "代码交付任务建议 worktree：scratch 完成即删，产物会丢",
    )
    parser.add_argument("--branch", help="worktree 分支前缀，如 claude")
    # ── 重试/超时/评审门：一律透传平台，套件不叠加自己的重试计数 ──
    parser.add_argument(
        "--max-retries",
        type=int,
        help="平台连续失败熔断阈值（透传 --max-retries；默认取 dispatcher failure_limit=2）",
    )
    parser.add_argument(
        "--max-runtime",
        help="单卡运行上限（透传 --max-runtime，如 30m/2h/1d）：超时 SIGTERM 并重排队",
    )
    parser.add_argument(
        "--completion-contract",
        help="完成契约（透传 --completion-contract）：local / OWNER/REPO / PR URL；"
        "用于把「完成」绑定到 PR 与 CI 门，而不是自述",
    )
    parser.add_argument(
        "--skill",
        action="append",
        help="强制给 worker 挂技能（可重复，透传 --skill）",
    )
    parser.add_argument(
        "--skip-preflight", action="store_true", help="跳过环境闸门（不推荐）"
    )
    parser.add_argument(
        "--require-dispatcher",
        action="store_true",
        help="环境闸门严格模式：调度器未运行即拒发（默认降级为串行提示）",
    )
    args = parser.parse_args(argv)

    scope_check = _load_scope_check()
    tasks_path = Path(args.tasks)
    if not tasks_path.is_file():
        print(f"✗ 任务文件不存在：{tasks_path}", file=sys.stderr)
        return 2

    tasks = scope_check.parse_tasks_yaml(
        tasks_path.read_text(encoding="utf-8", errors="replace")
    )
    if not tasks:
        print("✗ 未解析到任务（检查 tasks.yaml 格式）", file=sys.stderr)
        return 2

    # ═══ 闸门 1：环境 ═══
    pf_rc, pf_out = (0, "") if args.skip_preflight else preflight(args.require_dispatcher)
    if pf_rc == 2:
        print(f"✗ 环境闸门未过（NOT READY）：{pf_out}", file=sys.stderr)
        return 1

    # ═══ 闸门 2：文件边界互斥 ═══
    report = scope_check.analyze(tasks)
    if not report.ok:
        print(scope_check.render_human(report), file=sys.stderr)
        print("✗ 边界闸门未过：禁止并行派发（改串行或重划 files_scope）", file=sys.stderr)
        return 1

    # ═══ 闸门 3：语义指纹幂等 ═══
    fingerprints = report.fingerprints
    results: list[dict[str, Any]] = []
    for task in tasks:
        fp = fingerprints[task.task_id]
        cmd = build_create_cmd(
            task, fp, args.board, args.workspace, args.branch, args.assignee,
            max_retries=args.max_retries,
            max_runtime=args.max_runtime,
            completion_contract=args.completion_contract,
            skills=args.skill,
        )
        entry: dict[str, Any] = {
            "task_id": task.task_id,
            "fingerprint": fp,
            "cmd": cmd,
            "dry_run": args.dry_run,
        }
        if args.dry_run:
            entry["status"] = "preview"
        else:
            proc = subprocess.run(cmd, capture_output=True, text=True,
                                  encoding="utf-8", errors="replace")
            entry["status"] = "created" if proc.returncode == 0 else "failed"
            entry["rc"] = proc.returncode
            raw = (proc.stdout or "").strip()
            entry["stdout"] = raw[:500]
            # 解析平台返回的卡 id：制度层 S4 硬闸门要求「每张卡必须报告 t_xxxxxxxx」
            try:
                payload = json.loads(raw)
                entry["kanban_id"] = payload.get("id")
                entry["kanban_status"] = payload.get("status")
                entry["workspace_kind"] = payload.get("workspace_kind")
            except (json.JSONDecodeError, AttributeError):
                entry["kanban_id"] = None
            if proc.returncode != 0:
                entry["stderr"] = (proc.stderr or "").strip()[:500]
        results.append(entry)

    if args.json:
        print(json.dumps(
            {
                "preflight_rc": pf_rc,
                "degraded": pf_rc == 1,
                "tasks": results,
            },
            ensure_ascii=False,
            indent=2,
        ))
    else:
        if pf_rc == 1:
            print("⚠ 环境闸门 DEGRADED：调度器未运行 —— 允许建卡，但不会有自动认领；"
                  "按制度层降级为串行执行 + 人工对账")
        for entry in results:
            mark = "·" if args.dry_run else ("✓" if entry["status"] == "created" else "✗")
            kid = entry.get("kanban_id") or ""
            kstatus = entry.get("kanban_status") or ""
            print(f"{mark} {entry['task_id']} [{entry['fingerprint']}] "
                  f"{entry['status']} {kid} {kstatus}".rstrip())
            if args.dry_run:
                print("    " + " ".join(entry["cmd"]))
            elif entry["status"] == "failed":
                print(f"    rc={entry.get('rc')} {entry.get('stderr', '')}")
        if not args.dry_run:
            ids = [e.get("kanban_id") for e in results]
            if any(not i for i in ids):
                print("✗ 有卡未返回看板 id：S4 未准出（禁止进入 S5）")
            else:
                print(f"S4 准出证据：{len(ids)} 张卡全部上板 → " + ", ".join(str(i) for i in ids))
    return 0 if all(e["status"] in ("created", "preview") for e in results) else 2


if __name__ == "__main__":
    sys.exit(main())
