#!/usr/bin/env python3
"""sentinel_tick.py — 哨兵 cron 入口（T-KIT-P3A 任务卡 §2.2，纯标准库）

无参数即可运行；内部用 subprocess 调一轮 card-sentinel.py，透传 stdout，
把汇总行追加进 logs/tick.log，并复用 card-sentinel 的写函数更新 state 的
pid / updated_at / last_tick（不另写一份格式）。

设计要点：
- 退出码 0 恒为正常（内部异常也写日志、返回 0，避免 cron 报警噪音）；
  只有 python 自身不可用才会非 0（那种情况本文件根本跑不起来）。
- logs/ 不存在要自己 mkdir -p。
- 支持 --dry-run 透传给 card-sentinel.py。

用法：
    python scripts/sentinel_tick.py [--dry-run]
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from datetime import datetime

from wf_common import env

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

# card-sentinel 与本文件共享 state 路径解析（WF_STATE_FILE 优先，
# 缺省 <repo>/logs/sentinel_state.json）——同一处默认，避免两处漂移
STATE_FILE = os.path.join(REPO_ROOT, "logs", "sentinel_state.json")


def tick_log_path() -> str:
    return os.path.join(REPO_ROOT, "logs", "tick.log")


def parse_summary(stdout: str) -> tuple[int, int, int]:
    """从 card-sentinel stdout 提取 TICK_SUMMARY 行 → (dispatched, skipped, total_ready)。

    解析不到（环境错误 rc=2 时只有 ERROR 行）→ 全 0，日志行照写。
    """
    dispatched = skipped = total_ready = 0
    for line in stdout.splitlines():
        if line.startswith("TICK_SUMMARY "):
            for kv in line[len("TICK_SUMMARY "):].split():
                if "=" not in kv:
                    continue
                k, _, v = kv.partition("=")
                try:
                    if k == "dispatched":
                        dispatched = int(v)
                    elif k == "skipped":
                        skipped = int(v)
                    elif k == "total_ready":
                        total_ready = int(v)
                except ValueError:
                    pass
            break
    return dispatched, skipped, total_ready


def update_state_meta() -> None:
    """更新 state 的 pid / updated_at / last_tick。

    复用 card-sentinel 的 load_state / save_state（不另写一份格式）：
    import 而非复制代码，schema 与原子写语义天然一致。state 不存在时不
    凭空造——card-sentinel 本轮 rc=0 时已写过，tick 只做补充更新。
    """
    # card-sentinel.py 不带 .py 后缀也能 import（模块名含连字符不能直接
    # import，这里用 importlib 按路径加载）
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "card_sentinel", os.path.join(SCRIPT_DIR, "card-sentinel.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    sp = env("WF_STATE_FILE", "") or mod.state_path()
    if not os.path.isfile(sp):
        return
    try:
        st = mod.load_state(sp)
        st["pid"] = os.getpid()
        st["updated_at"] = mod.iso_now()
        st["last_tick"] = mod.iso_now()
        mod.save_state(sp, st)
    except OSError:
        pass


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description="哨兵 cron 入口：跑一轮 card-sentinel 并记 tick 日志")
    ap.add_argument("--dry-run", action="store_true",
                    help="透传给 card-sentinel.py")
    args = ap.parse_args(argv)

    logs_dir = os.path.join(REPO_ROOT, "logs")
    try:
        os.makedirs(logs_dir, exist_ok=True)
    except OSError:
        pass

    sentinel_py = os.path.join(SCRIPT_DIR, "card-sentinel.py")
    cmd = [sys.executable, sentinel_py]
    if args.dry_run:
        cmd.append("--dry-run")

    dispatched = skipped = total_ready = 0
    rc = 1
    stdout_text = ""
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=7200)
        rc = proc.returncode
        stdout_text = proc.stdout.decode("utf-8", errors="replace")
    except (OSError, subprocess.TimeoutExpired) as exc:
        stdout_text = f"ERROR sentinel_tick 内部异常：{exc}"
        rc = 1

    # 透传 card-sentinel 的输出（dry-run 的 WOULD_DISPATCH/SKIP、正常轮的日志）
    sys.stdout.write(stdout_text)

    # 无条件追加一行 tick 日志（内部异常也写，rc 记实）
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    dispatched, skipped, total_ready = parse_summary(stdout_text)
    line = (f"{now} rc={rc} dispatched={dispatched} skipped={skipped} "
            f"total_ready={total_ready}\n")
    try:
        with open(tick_log_path(), "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass

    # 更新 state 元信息（rc=0 时 card-sentinel 已写过完整 state；tick 补 pid）
    if rc == 0 and not args.dry_run:
        update_state_meta()

    # 退出码 0 恒为正常（内部异常也返回 0，避免 cron 报警噪音）
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
