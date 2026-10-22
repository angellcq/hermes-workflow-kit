#!/usr/bin/env python3
"""card-sentinel.py — 看板哨兵判定器（T-KIT-P3A 任务卡 §2.1，纯标准库）

定时扫板，把符合条件、assignee 属于 cc- 前缀的 ready 卡交给派单器
（scripts/dispatch-lane.sh，T-KIT-P2 交付）。判定流程顺序不可换：

    1. hermes kanban list --json 取卡（find_hermes() 已处理 MSYS/.exe 归一）
    2. 只要 status == "ready"；claimed（= running）打印 SKIP claimed 后跳过
    3. 只碰 assignee 以 WF_AGENT_PREFIX（默认 cc-）开头的卡，其余一律不动
    4. 冷却：cooldown[tid] 未到期 → SKIP cooldown
    5. 熔断：fails[tid] >= WF_FAIL_FUSE → block(needs_input) + SKIP fused
    6. 并发：全局 running >= WF_MAX_CONCURRENT → SKIP global-limit；
       同 agent running >= WF_MAX_PER_AGENT → SKIP agent-busy
    7. 通过 → bash scripts/dispatch-lane.sh <tid> <assignee> "<prompt>" <repo> <board>

两条铁律的落点：

- 为什么必须落盘（state 用 os.replace 原子写）：cron 每轮都是新进程，
  内存计数必清零——不落盘就会无限重派同一张失败卡。
- 为什么只碰 cc- 前缀：网关内置 dispatcher 只会 spawn Hermes profile
  （profile_exists 硬闸门），真 profile 名（hm-*）的卡它自己会派，哨兵再碰
  就是双写；cc-* 路由键网关永远派不出去，只有哨兵会派。

CLI：
    python scripts/card-sentinel.py [--board B] [--dry-run] [--state PATH]
                                   [--max-concurrent N] [--max-per-agent N]

--dry-run 只打印计划（WOULD_DISPATCH / SKIP），不写 state、不调派单器、不动卡。

退出码：0 正常（含 0 张可派）/ 2 环境错误（找不到 board、hermes 不可执行、
state 目录不可写）。
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime

from wf_common import env, find_hermes, load_config

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

DEFAULT_AGENT_PREFIX = "cc-"
DEFAULT_FAIL_FUSE = 3
DEFAULT_MAX_CONCURRENT = 2
DEFAULT_MAX_PER_AGENT = 1
DEFAULT_COOLDOWN_SECONDS = 300

DISPATCH_PROMPT = "请按任务卡 {tid} 的 TASK.md 执行；完成后提交并打印改动清单。"

EXIT_OK = 0
EXIT_ENV = 2


class EnvError(Exception):
    """环境错误（找不到 board / hermes 不可执行 / state 目录不可写）→ exit 2。"""


def iso_now() -> str:
    """ISO 时间戳带本地时区偏移（schema 要求 +08:00 形态）。"""
    return datetime.now().astimezone().isoformat(timespec="seconds")


def state_path() -> str:
    """state 落盘路径：WF_STATE_FILE 优先，缺省 <repo>/logs/sentinel_state.json。"""
    custom = env("WF_STATE_FILE", "")
    if custom:
        return custom
    return os.path.join(REPO_ROOT, "logs", "sentinel_state.json")


def load_state(path: str) -> dict:
    """读 state；不存在/损坏 → 空骨架（沿用固定 schema 键位）。"""
    st: dict = {"cooldown": {}, "fails": {}, "dispatched_total": 0}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            st.update(data)
    except (OSError, json.JSONDecodeError):
        pass
    if not isinstance(st.get("cooldown"), dict):
        st["cooldown"] = {}
    if not isinstance(st.get("fails"), dict):
        st["fails"] = {}
    if not isinstance(st.get("dispatched_total"), int):
        st["dispatched_total"] = 0
    return st


def save_state(path: str, state: dict) -> None:
    """state 原子落盘（os.replace）。

    【铁律】cron 每轮都是新进程，内存计数必清零——不落盘就会无限重派
    同一张失败卡。所以每轮结束必写，且必须原子替换（半截 state 比没有
    state 更危险：fails 丢失等于熔断清零）。
    """
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load_cards(board: str, cfg: dict) -> list[dict]:
    """hermes kanban list --json 取卡。hermes 不可执行/输出非 JSON → EnvError。"""
    hermes = find_hermes(cfg=cfg)
    try:
        proc = subprocess.run(
            [hermes, "kanban", "--board", board, "list", "--json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise EnvError(f"hermes 不可执行：{exc}")
    if proc.returncode != 0:
        raise EnvError(
            f"hermes kanban list 失败 rc={proc.returncode}："
            f"{proc.stderr.decode('utf-8', errors='replace').strip()[:200]}"
        )
    try:
        data = json.loads(proc.stdout.decode("utf-8", errors="replace"))
    except json.JSONDecodeError as exc:
        raise EnvError(f"hermes kanban list --json 输出不是合法 JSON：{exc}")
    if isinstance(data, dict):
        # 防御性兼容：万一未来包装成 {"tasks": [...]}
        data = data.get("tasks") or data.get("cards") or []
    return [c for c in data if isinstance(c, dict)]


def block_fused(board: str, tid: str, fail_n: int, cfg: dict) -> None:
    """熔断落卡：block --kind needs_input（blocked 态等人工介入）。

    用法核对（hermes kanban block --help）：reason 是【位置参数】，没有
    -m/--message——曾有实现传 "-m ..." 被 argparse 拒收，而 DEVNULL 把
    错误吞掉，熔断打印了 fused 卡却没被 block（S5 实测事故）。所以：
    reason 走位置参数；错误必须可见（捕获 stderr 末行打印），block 失败
    不致命（卡还在 ready，下轮熔断判定会再试），但不许静默。
    """
    hermes = find_hermes(cfg=cfg)
    try:
        proc = subprocess.run(
            [hermes, "kanban", "--board", board, "block", tid,
             "--kind", "needs_input",
             f"哨兵熔断：连续 {fail_n} 次派单失败，需人工介入"],
            capture_output=True, text=True,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"ERROR block {tid}: {exc}")
        return
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip().splitlines()
        print(f"ERROR block {tid}: "
              f"{tail[-1] if tail else f'rc={proc.returncode}, 无输出'}")


def dispatch_card(tid: str, assignee: str, board: str, cfg: dict) -> int:
    """调派单器。返回 dispatch-lane.sh 退出码（0/1/3/其他，语义见其文件头）。

    不设 timeout：worker（claude -p）可能跑很久，串行等待是设计行为。
    路径铁律：dispatch-lane.sh 与 repo 都过原生归一（SCRIPT_DIR 由
    __file__ 派生，已是原生形态；REPO_ROOT 同理）。
    """
    bash = shutil.which("bash") or "bash"
    script = os.path.join(SCRIPT_DIR, "dispatch-lane.sh")
    prompt = DISPATCH_PROMPT.format(tid=tid)
    try:
        proc = subprocess.run(
            [bash, script, tid, assignee, prompt, REPO_ROOT, board],
            stdout=None,
            stderr=None,
        )
        return proc.returncode
    except OSError as exc:
        print(f"ERROR {tid} dispatch-lane 启动失败：{exc}")
        return 2


def _int_env(name: str, default: int, cfg: dict) -> int:
    raw = env(name, str(default), cfg=cfg)
    try:
        return int(raw)
    except ValueError:
        print(f"ERROR 配置 {name}={raw!r} 不是整数，用缺省 {default}")
        return default


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description="看板哨兵：扫板把 cc- 前缀 ready 卡交给派单器（T-KIT-P3A）")
    ap.add_argument("--board", default=None, help="板名（缺省取 WF_BOARD）")
    ap.add_argument("--dry-run", action="store_true",
                    help="只打印计划，不写 state、不调派单器、不动卡")
    ap.add_argument("--state", default=None, help="state 落盘路径")
    ap.add_argument("--max-concurrent", type=int, default=None,
                    help="全局最大并发（缺省取 WF_MAX_CONCURRENT，默认 2）")
    ap.add_argument("--max-per-agent", type=int, default=None,
                    help="单 agent 最大并发（缺省取 WF_MAX_PER_AGENT，默认 1）")
    args = ap.parse_args(argv)

    cfg = load_config()

    board = args.board or env("WF_BOARD", "", cfg=cfg)
    if not board:
        print("ERROR 环境错误：板名必填（--board 或 WF_BOARD；"
              "kanban/current 是全局指针会漂移，不许缺省）")
        return EXIT_ENV

    sp = args.state or state_path()
    max_concurrent = args.max_concurrent
    if max_concurrent is None:
        max_concurrent = _int_env("WF_MAX_CONCURRENT", DEFAULT_MAX_CONCURRENT, cfg)
    max_per_agent = args.max_per_agent
    if max_per_agent is None:
        max_per_agent = _int_env("WF_MAX_PER_AGENT", DEFAULT_MAX_PER_AGENT, cfg)
    prefix = env("WF_AGENT_PREFIX", DEFAULT_AGENT_PREFIX, cfg=cfg)
    fuse = _int_env("WF_FAIL_FUSE", DEFAULT_FAIL_FUSE, cfg)
    cooldown_s = _int_env("WF_COOLDOWN_SECONDS", DEFAULT_COOLDOWN_SECONDS, cfg)

    if not args.dry_run:
        # state 目录不可写 → 环境错误（dry-run 不落盘，不做此检查）
        try:
            os.makedirs(os.path.dirname(sp) or ".", exist_ok=True)
        except OSError as exc:
            print(f"ERROR 环境错误：state 目录不可写 {sp}：{exc}")
            return EXIT_ENV

    state = load_state(sp)
    cards = load_cards(board, cfg)  # EnvError → exit 2

    now = int(time.time())
    running = [c for c in cards if c.get("status") == "running"]

    dispatched = 0
    skipped = 0
    total_ready = 0

    for card in cards:
        tid = str(card.get("id") or "")
        status = str(card.get("status") or "")
        # 非 ready 一律不碰，但 claimed（= running）必须打印——这是实测盲区：
        # claim_lock 未随 block 释放时，下轮哨兵命中"已 claim"却一行不打印，
        # 排错时只见无关卡输出，看不出"这张为什么没派"。（list --json 不返回
        # claim_lock 字段，claimed 的唯一可见形态就是 status == running，实测
        # 验证；claim_lock 分支保留为 schema 前向兼容，未来补字段时无需改码。）
        if status != "ready":
            if status == "running":
                print(f"SKIP {tid} claimed")
                skipped += 1
            continue
        total_ready += 1

        # ── 判定 2：已 claim 的跳过（打印见上，这里是字段级兼容）──
        if card.get("claim_lock"):
            print(f"SKIP {tid} claimed")
            skipped += 1
            continue

        # ── 判定 3：只碰 cc- 前缀 ──
        # 空 assignee / hm-* / 真 profile 名一律不碰——真 profile 名的卡网关
        # dispatcher 自己会派，哨兵再派就是双写。
        assignee = str(card.get("assignee") or "").strip()
        if not assignee.startswith(prefix):
            print(f"SKIP {tid} assignee-not-lane")
            skipped += 1
            continue

        # ── 判定 4：冷却 ──
        if now < int(state["cooldown"].get(tid, 0)):
            print(f"SKIP {tid} cooldown")
            skipped += 1
            continue

        # ── 判定 5：熔断 ──
        # 熔断后不再派，除非 state 里该 tid 被清掉；同时落 block（needs_input）
        # 让卡离开 ready，等人工介入。
        fail_n = int(state["fails"].get(tid, 0))
        if fail_n >= fuse:
            print(f"SKIP {tid} fused (fails={fail_n} >= WF_FAIL_FUSE={fuse})")
            skipped += 1
            if not args.dry_run:
                block_fused(board, tid, fail_n, cfg)
            continue

        # ── 判定 6：并发上限 ──
        if len(running) >= max_concurrent:
            print("SKIP global-limit")
            skipped += 1
            continue
        agent_running = sum(
            1 for c in running
            if str(c.get("assignee") or "").strip() == assignee)
        if agent_running >= max_per_agent:
            print(f"SKIP {tid} agent-busy")
            skipped += 1
            continue

        # ── 判定 7：派单 ──
        if args.dry_run:
            print(f"WOULD_DISPATCH {tid} {assignee}")
            dispatched += 1
            continue

        rc = dispatch_card(tid, assignee, board, cfg)
        dispatched += 1
        if rc == 0:
            # 成功：清失败计数与冷却（连续失败才熔断，成功即归零）
            state["fails"].pop(tid, None)
            state["cooldown"].pop(tid, None)
            state["dispatched_total"] += 1
        else:
            # 1/3 = 产出校验未通过 / 守卫拒绝；其他（含 2）= 参数或环境错误
            # —— 都计一次失败并进冷却，防止下轮立即重派打转。
            if rc not in (1, 3):
                print(f"ERROR {tid} dispatch-lane rc={rc} (unexpected), counted as fail")
            state["fails"][tid] = fail_n + 1
            state["cooldown"][tid] = now + cooldown_s

    if not args.dry_run:
        state["board"] = board
        state["pid"] = os.getpid()
        state["updated_at"] = iso_now()
        state["last_tick"] = iso_now()
        try:
            save_state(sp, state)
        except OSError as exc:
            print(f"ERROR 环境错误：state 落盘失败 {sp}：{exc}")
            return EXIT_ENV

    # 机器可读汇总行：sentinel_tick.py 解析它写 tick.log
    print(f"TICK_SUMMARY dispatched={dispatched} skipped={skipped} "
          f"total_ready={total_ready}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
