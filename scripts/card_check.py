#!/usr/bin/env python3
"""card_check.py — 派单产出校验判定器（T-KIT-P2 任务卡 §2.2，纯标准库）

两个子命令：

    python card_check.py snapshot <project_dir>
        → stdout 一行：<HEAD sha 或 "none">\t<工作区指纹>
          工作区指纹 = md5("\n".join(sorted(git status --porcelain 的行)))

    python card_check.py verdict <project_dir> <board> <task_id> <snapshot_before>
        → exit 0 = produced / exit 1 = EMPTY（零产出）/ exit 2 = skip（不适用）
          / exit 3 = 用法错误
        stdout 一行说明（会被写进看板评论）

三条硬约束（缺一不可，都有真实事故背书）：

1. 验证型卡只匹配**标题**，禁止匹配正文。实测：修复卡正文里天然含
   "验收/只读/对照实验"等词，连正文一起匹配会把修复卡误判成验证型卡
   → 放过零产出 → 假 done 直通。所以关键词只对 `Task <id>: <标题>` 行生效。

2. 快照必须由本脚本（Python）统一生成，bash 侧只负责原样带回。
   曾有实现让 bash 用 `git status --porcelain | md5sum` 自己算：
   bash 拿到 CRLF、Python 拿到 LF ⇒ 两侧指纹永不相同 ⇒ 判定恒为"有产出"
   ⇒ 守卫看着在、其实从未生效。所以 snapshot 与 verdict 的指纹算法
   必须是同一段 Python 代码（本文件的 _fingerprint），bash 一律透传字符串。

3. 判定器异常退出（非 0/1/2）必须由调用方显式降级（dispatch-lane.sh 守卫⑥
   的"非 0/1/2 → 视为 skip 但评论写明异常"分支），不许静默 fail-open。

判定顺序（不可换，见 verdict 的实现与 TASK.md §2.2 表格）：

    1. SKIP_PRODUCE_CHECK=1                          → skip(2)
    2. 项目目录不是 git 仓库                          → skip(2)
    3. HEAD 变化                                     → produced(0)
    4. 工作区指纹变化                                 → produced(0)
    5. 卡标题命中验证型关键词                          → skip(2)
    6. 取不到卡内容（show 失败/解析不到标题）           → EMPTY(1)（按有风险处理）
    7. 其余                                           → EMPTY(1)
"""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys

from wf_common import env, find_hermes, native_path

# 验证型关键词默认表（只匹配卡标题！），WF_VERIFY_KEYWORDS（逗号分隔）可覆盖
DEFAULT_VERIFY_KEYWORDS = "验收,巡检,复核,盘点,闭环,演练,审计,只读,排查,对照实验"

EXIT_PRODUCED = 0
EXIT_EMPTY = 1
EXIT_SKIP = 2
EXIT_USAGE = 3


def _run_git(project_dir: str, *args: str) -> tuple[int, str, str]:
    """在 project_dir 跑 git 命令，返回 (rc, stdout, stderr)。

    注意：输出不做任何换行翻译（text=True 但保原始字节再手动解码且不
    replace），后续指纹计算依赖 \n 严格分隔。subprocess 在 Windows 下
    默认会把 \r\n 保留原样（universal_newlines 不做 strip），手动 decode
    更可控。
    """
    try:
        proc = subprocess.run(
            ["git", "-C", project_dir, *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
        )
        return (
            proc.returncode,
            proc.stdout.decode("utf-8", errors="replace"),
            proc.stderr.decode("utf-8", errors="replace"),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, "", str(exc)


def _fingerprint(lines: list[str]) -> str:
    """工作区指纹：md5("\n".join(sorted(status --porcelain 的行)))。

    【硬约束 2 的落点】指纹算法只有这一份，snapshot 与 verdict 都走这里。
    porcelain 行内的 \r（Windows git 可能输出 CRLF）统一剥掉后再 join，
    保证同一次快照无论 bash 如何传递（echo/命令替换会碰行尾），
    Python 侧看到的都是规范的 LF 分隔序列。
    """
    cleaned = [ln.rstrip("\r\n") for ln in lines if ln.strip()]
    joined = "\n".join(sorted(cleaned))
    return hashlib.md5(joined.encode("utf-8")).hexdigest()


def cmd_snapshot(project_dir: str) -> int:
    """打印 "<HEAD sha 或 none>\t<指纹>"。git 不可用/非 git 仓库 → none\tnone。"""
    project_dir = native_path(project_dir)

    rc, out, _ = _run_git(project_dir, "rev-parse", "HEAD")
    head = out.strip() if rc == 0 else "none"

    rc_p, out_p, _ = _run_git(project_dir, "status", "--porcelain")
    if rc_p != 0:
        fp = "none"
    else:
        # splitlines 会把 CRLF 一起断行；_fingerprint 内部再剥 \r 兜底
        fp = _fingerprint(out_p.splitlines())

    print(f"{head}\t{fp}")
    return EXIT_PRODUCED


def _task_title(board: str, task_id: str) -> str:
    """取卡标题：`hermes kanban --board <board> show <task_id>` 输出里
    `Task <id>: <标题>` 行，取冒号后内容；取不到返回空串。

    【硬约束 1 的落点】只取这一行的标题部分，正文（Body: 之后）永远
    不参与关键词匹配——修复卡正文天然含"验收/只读"等词，混入正文
    会把修复卡误判成验证型卡。
    """
    hermes = find_hermes()
    try:
        proc = subprocess.run(
            [hermes, "kanban", "--board", board, "show", task_id],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
        )
        if proc.returncode != 0:
            return ""
        out = proc.stdout.decode("utf-8", errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        return ""

    m = re.search(rf"^Task\s+{re.escape(task_id)}\s*:\s*(.*)$", out, re.MULTILINE)
    if not m:
        return ""
    return m.group(1).strip()


def _verify_keywords() -> list[str]:
    raw = env("WF_VERIFY_KEYWORDS", DEFAULT_VERIFY_KEYWORDS)
    return [k.strip() for k in raw.split(",") if k.strip()]


def cmd_verdict(project_dir: str, board: str, task_id: str, snapshot_before: str) -> int:
    """三态判定。退出码即判定结果：0 produced / 1 EMPTY / 2 skip / 3 用法错误。"""
    # ---- 参数与快照格式校验（用法错误 → 3）----
    if not project_dir or not board or not task_id:
        print("用法错误：verdict 需要 <project_dir> <board> <task_id> <snapshot_before>")
        return EXIT_USAGE
    if "\t" not in snapshot_before:
        print(f"用法错误：snapshot_before 格式应为 <HEAD>\\t<指纹>，实际收到：{snapshot_before!r}")
        return EXIT_USAGE
    head_before, fp_before = snapshot_before.split("\t", 1)

    # ---- 判定顺序 1：显式跳过 ----
    # 为什么放第一位：操作员显式声明"这卡不用校验"（如跑在非 git 目录的旁路任务），
    # 优先级高于一切自动判定。
    if os.environ.get("SKIP_PRODUCE_CHECK") == "1":
        print("SKIP_PRODUCE_CHECK=1，按任务卡约定跳过产出校验")
        return EXIT_SKIP

    project_dir = native_path(project_dir)

    # ---- 判定顺序 2：非 git 仓库 → skip ----
    # 产出校验的物理前提是 git 快照可算；非 git 目录（如纯文档工作区）
    # 没有可比较的状态，判 EMPTY 只会制造噪音，判 skip 并留下说明。
    rc_is, out_is, _ = _run_git(project_dir, "rev-parse", "--is-inside-work-tree")
    if rc_is != 0 or out_is.strip() != "true":
        print(f"{project_dir} 不是 git 仓库，产出校验不适用")
        return EXIT_SKIP

    # ---- 快照 After ----
    rc_head, out_head, _ = _run_git(project_dir, "rev-parse", "HEAD")
    head_after = out_head.strip() if rc_head == 0 else "none"

    rc_fp, out_fp, _ = _run_git(project_dir, "status", "--porcelain")
    fp_after = _fingerprint(out_fp.splitlines()) if rc_fp == 0 else "none"

    head_changed = (head_before != head_after)
    fp_changed = (fp_before != fp_after)

    # ---- 判定顺序 3/4：HEAD 或工作区指纹变化 → produced ----
    # 顺序 3（HEAD）先于 4（工作区）：提交是更强信号；只改文件未提交也要算
    # 产出（历史事故：改动只躺工作区、被下一个 worker 覆盖——工作区指纹
    # 正是为这种"提交了才算产出"的偏松口径兜底）。
    if head_changed or fp_changed:
        parts = []
        if head_changed:
            parts.append(f"HEAD {head_before} → {head_after}")
        if fp_changed:
            parts.append(f"工作区指纹 {fp_before} → {fp_after}")
        print(f"produced: {'；'.join(parts)}")
        return EXIT_PRODUCED

    # ---- 判定顺序 5：卡标题命中验证型关键词 → skip ----
    title = _task_title(board, task_id)
    if title:
        for kw in _verify_keywords():
            if kw in title:
                print(f"卡标题命中验证型关键词「{kw}」（验证型卡不要求 git 产出）")
                return EXIT_SKIP

    # ---- 判定顺序 6：取不到卡内容 → EMPTY（按有风险处理）----
    # 取不到标题有两种可能：看板命令挂了 / 解析格式漂移。这时没法证明它
    # 是验证型卡，宁可按零产出处理（fail-closed），也不能放过假 done。
    if not title:
        print("EMPTY：取不到卡内容，按有风险处理（零产出 + 无法确认是否验证型）")
        return EXIT_EMPTY

    # ---- 判定顺序 7：其余 → EMPTY ----
    print(f"EMPTY：HEAD 与工作区均无变化，判定零产出（卡标题：{title}）")
    return EXIT_EMPTY


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return EXIT_USAGE
    cmd = argv[1]
    if cmd == "snapshot" and len(argv) == 3:
        return cmd_snapshot(argv[2])
    if cmd == "verdict" and len(argv) == 6:
        return cmd_verdict(argv[2], argv[3], argv[4], argv[5])
    print(__doc__)
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv))
