#!/usr/bin/env python
"""看板巡检指纹器 — Hermes Workflow Kit

给 Hermes cron 的 monitor 模式当变化探测器：每个 tick 输出当前
「派发后需要有人处置」的异常指纹。指纹不变 → cron 不唤醒 agent（零 token）；
指纹一变（卡完成/超时/悬空/lane 进程死）→ 唤醒 agent 按 kanban-executor 规则处置。

设计约束（monitor 契约）：
  - 输出必须确定性：不含时间戳、不含年龄数值，年龄只用布尔阈值表达。
  - agent 处置动作（complete/archive/block/promote/reclaim/unblock/assign）会改变
    看板状态与诊断项，指纹随之变化 → 天然去重，无需状态文件。
  - 退出码恒为 0；自身异常输出 WATCHDOG_ERROR 行（下个 tick 若已修复自动消失）。

检查三路信号（状态词为看板 9 态真名，见 kanban-executor/references/kanban机制说明书.md §四）：
  1. hermes kanban list --json —— 悬空 ready 卡 / 超时 running 卡 /
     done 未验证卡 / blocked 带失败原因卡 / 汇总计数行
  2. agent-bridge 后台任务 —— ~/.workbuddy/agent-bridge/tasks/*/status.json：
     running 但 PID 已死（lane 断头）、running 且 PID 活着但日志超阈值无更新（疑似卡死）
  3. hermes kanban diagnostics --json —— 活跃诊断项（孤儿 claim_lock、blocked 超期等），
     每项输出一行 DIAG_ACTIVE <task_id>；处置规程见 kanban-executor「超时与孤儿回收」
  4. 哨兵活性（P3B 新增）—— logs/sentinel_state.json 的 mtime 判哨兵僵死（SENTINEL_DEAD）

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
SENTINEL_DEAD_SECONDS = int(os.environ.get("WF_SENTINEL_DEAD_SECONDS", 900))

TERMINAL_STATUSES = {"done", "archived", "cancelled"}

BRIDGE_TASK_BASE = Path(
    os.environ.get(
        "AGENT_BRIDGE_TASK_BASE",
        Path.home() / ".workbuddy" / "agent-bridge" / "tasks",
    )
)

# 哨兵工人的 assignee 前缀（P3B 新增）。卡必须是 cc-<角色> 才归 cc- 哨兵管；
# 真实 Hermes profile 名的卡会被网关内置 dispatcher 抢走（profile_exists 为真
# → spawn Hermes worker），与 cc- 哨兵双跑同一张卡、双写同一批文件。
WF_AGENT_PREFIX = os.environ.get("WF_AGENT_PREFIX", "cc-")

# 哨兵状态文件（P3B 新增）。sentinel_tick.py 每 tick touch 它；
# watchdog 按 mtime 判哨兵是否还活着。测试用 WF_STATE_FILE 指到临时目录。
SENTINEL_STATE_FILE = Path(
    os.environ.get(
        "WF_STATE_FILE",
        Path(__file__).resolve().parent.parent / "logs" / "sentinel_state.json",
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
    # P3B 新增：真实 Hermes profile 名单（防 assignee 漂移判据三）。best-effort：
    # 取不到（旧版本无子命令 / 网关没跑）只按前两条判，失败不许报 ERROR。
    real_profiles: set[str] = set()
    try:
        assignees_out = subprocess.run(
            [find_hermes(), "kanban", "assignees", "--json"],
            capture_output=True, text=True, timeout=60,
        )
        if assignees_out.returncode == 0:
            for a in json.loads(assignees_out.stdout):
                if a.get("name") and a.get("on_disk"):
                    real_profiles.add(a["name"])
        # 空 on_disk 名单 = 本机无真实 profile，判据三自然全不命中，无需特判
    except (subprocess.TimeoutExpired, OSError, json.JSONDecodeError):
        real_profiles = set()  # best-effort：不报 WATCHDOG_ERROR，不误报
    for t in tasks:
        status = t.get("status") or "unknown"
        counts[status] = counts.get(status, 0) + 1
        tid = t.get("id", "?")
        if status == "ready" and not t.get("assignee"):
            lines.append(f"CLAIM_PENDING {tid}")
        if status == "ready":
            # P3B 新增 ASSIGNEE_DRIFT（与上面 CLAIM_PENDING 有意并存，同一张卡可两行）：
            # CLAIM_PENDING 说"没人认领"，ASSIGNEE_DRIFT 说"有被网关抢单风险"，
            # 语义不同、处置不同（前者补派 lane，后者立即改 assignee）。
            # 命中：assignee 为空 / 不以 cc- 开头 / 是真实 Hermes profile 名。
            assignee = t.get("assignee") or ""
            drift = (
                not assignee
                or not assignee.startswith(WF_AGENT_PREFIX)
                or assignee in real_profiles
            )
            if drift:
                lines.append(f"ASSIGNEE_DRIFT {tid} {assignee or 'empty'}")
        elif status == "running" and t.get("started_at"):
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
            # 唤醒信号：终态未确认（无 ack 文件）时报 BRIDGE_LANE_DONE，
            # 驱动巡检 agent 验收产出并闭环看板卡；处置完 touch <task_dir>/ack
            # 本行消失（指纹只在"新完成"时变化一次，避免每轮重复唤醒）。
            if not (sd / "ack").exists():
                lines.append(f"BRIDGE_LANE_DONE {sd.name} {status}")
            continue
        if status in ("running", "starting"):
            pid = int(st.get("pid") or 0)
            if not pid_alive(pid):
                lines.append(f"BRIDGE_LANE_DEAD {sd.name}")
                continue
            logf = sd / "claude.log"
            if logf.is_file() and now - logf.stat().st_mtime > LANE_LOG_STALE:
                lines.append(f"BRIDGE_LANE_STALE {sd.name}")
    return lines


def diagnostics_lines(board: str | None) -> list[str]:
    """Active task-level diagnostics (stranded_in_ready, orphan claim_lock,
    stale blocked, ...) via `hermes kanban diagnostics --json`. Best-effort:
    older Hermes without the subcommand yields nothing (returncode != 0)."""
    cmd = [find_hermes(), "kanban"]
    if board:
        cmd += ["--board", board]
    cmd += ["diagnostics", "--json"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (subprocess.TimeoutExpired, OSError):
        return []
    if out.returncode != 0:
        return []  # command unavailable on this version — no signal, no false alarm
    try:
        items = json.loads(out.stdout)
    except json.JSONDecodeError:
        return []
    lines: list[str] = []
    for it in items if isinstance(items, list) else []:
        tid = it.get("task_id")
        if not tid:
            continue  # board-level info row (e.g. dispatch_profiles), not actionable
        for d in it.get("diagnostics") or []:
            kind = d.get("kind")
            if kind:
                lines.append(f"DIAG_ACTIVE {tid} {kind}")
    return lines


def sentinel_dead_lines() -> list[str]:
    """P3B 新增：哨兵僵死探测（cron 没 tick / 脚本崩 / 主机休眠 —— 卡挂着没人派
    且没人知道，历史事故：卡挂 20 小时真因主机休眠）。按 sentinel_state.json 的
    mtime 判，sentinel_tick.py 每 tick touch 它。"""
    sf = SENTINEL_STATE_FILE
    if not sf.is_file():
        # 首次部署会先出现一次，属正常：跑一次 sentinel_tick.py 后消失
        return ["SENTINEL_DEAD no-state"]
    age = time.time() - sf.stat().st_mtime
    if age > SENTINEL_DEAD_SECONDS:
        # monitor 契约要求输出确定性（不含时间戳）——但这里的年龄数值正是
        # 指纹本身（新鲜→无行，僵死→age= 行），僵死/恢复两个态之间指纹必变，
        # 不会造成每轮重复唤醒，故此处允许数值。
        return [f"SENTINEL_DEAD age={int(age)}s"]
    return []  # 哨兵活着：不输出任何行


def main() -> int:
    board = None
    args = sys.argv[1:]
    if "--board" in args:
        i = args.index("--board")
        if i + 1 < len(args):
            board = args[i + 1]
    try:
        out = (
            board_lines(board)
            + bridge_lines()
            + diagnostics_lines(board)
            + sentinel_dead_lines()  # P3B 新增：与 bridge_lines 同级
        )
    except Exception as e:  # noqa: BLE001 — watchdog 永不崩，异常即信号
        out = [f"WATCHDOG_ERROR {type(e).__name__}"]
    print("\n".join(sorted(set(out))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
