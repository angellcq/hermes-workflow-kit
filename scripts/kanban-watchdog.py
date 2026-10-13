#!/usr/bin/env python
"""看板巡检指纹器 — Hermes Workflow Kit

给 Hermes cron 的 monitor 模式当变化探测器：每个 tick 输出当前
「派发后需要有人处置」的异常指纹。指纹不变 → cron 不唤醒 agent（零 token）；
指纹一变（卡完成/超时/悬空/lane 进程死）→ 唤醒 agent 按 kanban-executor 规则处置。

设计约束（monitor 契约）：
  - 输出必须确定性：不含时间戳、不含年龄数值，年龄只用布尔阈值表达。
  - agent 处置动作（complete/archive/block/assign）会改变看板状态，
    指纹随之变化 → 天然去重，无需状态文件。
  - 退出码恒为 0；自身异常输出 WATCHDOG_ERROR 行（下个 tick 若已修复自动消失）。

检查两路信号：
  1. hermes kanban list --json —— 悬空 ready 卡 / 超时 in_progress 卡 /
     done 未验证卡 / blocked 带失败原因卡 / 汇总计数行
  2. agent-bridge 后台任务 —— ~/.workbuddy/agent-bridge/tasks/*/status.json：
     running 但 PID 已死（lane 断头）、running 且 PID 活着但日志超阈值无更新（疑似卡死）

用法：
    python kanban-watchdog.py [--board <slug>]
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# ── 阈值（秒），可用环境变量覆盖 ──────────────────────────────
IN_PROGRESS_TIMEOUT = int(os.environ.get("KANBAN_WATCHDOG_TIMEOUT", 8 * 3600))
LANE_LOG_STALE = int(os.environ.get("KANBAN_WATCHDOG_LANE_STALE", 2 * 3600))

TERMINAL_STATUSES = {"done", "archived", "cancelled"}

BRIDGE_TASK_BASE = Path(
    os.environ.get(
        "AGENT_BRIDGE_TASK_BASE",
        Path.home() / ".workbuddy" / "agent-bridge" / "tasks",
    )
)


def find_hermes() -> str:
    """解析 hermes 入口：PATH → HERMES_HOME/bin → 本机默认安装位。"""
    for name in ("hermes", "hermes.exe"):
        p = shutil.which(name)
        if p:
            return p
    home = os.environ.get("HERMES_HOME") or str(
        Path(os.environ.get("LOCALAPPDATA", Path.home())) / "hermes"
    )
    for cand in (
        Path(home) / "bin" / "hermes.exe",
        Path(home) / "bin" / "hermes",
    ):
        if cand.exists():
            return str(cand)
    return "hermes"


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes

        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259
        kernel32 = ctypes.windll.kernel32
        h = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            return False
        try:
            code = ctypes.c_ulong()
            if kernel32.GetExitCodeProcess(h, ctypes.byref(code)):
                return code.value == STILL_ACTIVE
            return False
        finally:
            kernel32.CloseHandle(h)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def board_lines(board: str | None) -> list[str]:
    cmd = [find_hermes(), "kanban", "list", "--json"]
    if board:
        cmd = [cmd[0], "kanban", "--board", board, "list", "--json"]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        return [f"WATCHDOG_ERROR kanban_list exit={out.returncode}"]
    try:
        tasks = json.loads(out.stdout)
    except json.JSONDecodeError:
        return ["WATCHDOG_ERROR kanban_list bad_json"]

    now = time.time()
    lines: list[str] = []
    counts: dict[str, int] = {}
    for t in tasks:
        status = t.get("status") or "unknown"
        counts[status] = counts.get(status, 0) + 1
        tid = t.get("id", "?")
        if status == "ready" and not t.get("assignee"):
            lines.append(f"CLAIM_PENDING {tid}")
        elif status in ("in_progress", "running") and t.get("started_at"):
            if now - t["started_at"] > IN_PROGRESS_TIMEOUT:
                lines.append(f"IN_PROGRESS_TIMEOUT {tid}")
        elif status == "done":
            # done 卡等待验收闭环（git diff + 编译 + 归档）；处置归档后此行消失
            ws = t.get("workspace_path") or "no-workspace"
            lines.append(f"DONE_UNVERIFIED {tid} {ws}")
        elif status == "blocked":
            reason = "has_error" if t.get("last_failure_error") else "no_error"
            lines.append(f"BLOCKED {tid} {reason}")
    summary = ",".join(f"{k}={counts[k]}" for k in sorted(counts))
    lines.insert(0, f"BOARD {summary}")
    return lines


def bridge_lines() -> list[str]:
    lines: list[str] = []
    if not BRIDGE_TASK_BASE.is_dir():
        return lines
    now = time.time()
    for sd in sorted(BRIDGE_TASK_BASE.iterdir()):
        sf = sd / "status.json"
        if not sf.is_file():
            continue
        try:
            st = json.loads(sf.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            lines.append(f"BRIDGE_STATUS_UNREADABLE {sd.name}")
            continue
        status = st.get("status", "unknown")
        if status in ("completed", "failed", "killed"):
            continue  # 桥任务终态由看板验收闭环负责，不重复报
        if status in ("running", "starting"):
            pid = int(st.get("pid") or 0)
            if not pid_alive(pid):
                lines.append(f"BRIDGE_LANE_DEAD {sd.name}")
                continue
            logf = sd / "claude.log"
            if logf.is_file() and now - logf.stat().st_mtime > LANE_LOG_STALE:
                lines.append(f"BRIDGE_LANE_STALE {sd.name}")
    return lines


def main() -> int:
    board = None
    args = sys.argv[1:]
    if "--board" in args:
        i = args.index("--board")
        if i + 1 < len(args):
            board = args[i + 1]
    try:
        out = board_lines(board) + bridge_lines()
    except Exception as e:  # noqa: BLE001 — watchdog 永不崩，异常即信号
        out = [f"WATCHDOG_ERROR {type(e).__name__}"]
    print("\n".join(sorted(set(out))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
