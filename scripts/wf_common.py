#!/usr/bin/env python3
"""wf_common.py — 派单器 Python 公共层（纯标准库）

card_check.py 与后续 P3 哨兵共用。同一个量只能有一处实现：
配置读取、环境变量优先级、路径归一、hermes 可执行定位全部收敛在这里。

T-KIT-P2 任务卡 §2.1。"""
from __future__ import annotations

import os
import re
import shutil

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# KEY= 行的解析：KEY 或 KEY="value"（去成对引号）
_ENV_LINE_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$')


def load_config() -> dict:
    """读 wf.env，返回 KEY->VALUE 字典。

    路径：环境变量 WF_ENV_FILE 优先，缺省 <SCRIPT_DIR>/../config/wf.env。
    文件不存在 → 返回 {}（不抛异常，fresh 部署没拷样例也能跑）。
    语法：KEY="value" 与 KEY=value 均可，成对引号去掉；# 注释行与空行跳过。
    """
    env_file = os.environ.get("WF_ENV_FILE") or os.path.join(
        SCRIPT_DIR, "..", "config", "wf.env"
    )
    cfg: dict = {}
    try:
        with open(env_file, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                m = _ENV_LINE_RE.match(line)
                if not m:
                    continue
                key, value = m.group(1), m.group(2).strip()
                # 去成对引号（只去一层，且必须两侧配对）
                if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                    value = value[1:-1]
                cfg[key] = value
    except OSError:
        # 文件不存在/不可读 → 空配置（调用方走 env() 的 default 兜底）
        return {}
    return cfg


def env(name: str, default: str = "", cfg=None) -> str:
    """读环境变量。优先级：真实环境变量 > cfg（wf.env）> default。

    为什么 cfg 参数可显式传入：调用方（如 dispatch-lane.sh 循环里）可能
    一次 load_config 后反复取键，避免重复读盘。传 None 则现场 load 一次。
    """
    v = os.environ.get(name)
    if v is not None and v != "":
        return v
    if cfg is None:
        cfg = load_config()
    v = cfg.get(name)
    if v is not None and v != "":
        return v
    return default


def native_path(p: str) -> str:
    """路径归一，供原生 Windows Python 使用。

    这是踩过的坑：git-bash 的 /d/tmp 传给原生 python 会 chdir 失败
    （NotADirectoryError）。MSYS 路径只是 bash 的视图，原生解释器不认识。
    转换规则：
      - 展开 ~ / $HOME / ${HOME} 与全部 %VAR% / ${VAR} 环境变量
      - os.name == 'nt' 时把 MSYS 形式 /c/xx 或 /cygdrive/c/xx → C:/xx
      - 反斜杠统一为正斜杠（便于字符串比较与打印）
    """
    if not p:
        return p
    out = os.path.expanduser(p)
    out = os.path.expandvars(out)

    if os.name == "nt":
        m = re.match(r'^/cygdrive/([A-Za-z])(?:/(.*)|)$', out)
        if m:
            out = f"{m.group(1).upper()}:/{m.group(2) or ''}"
        else:
            m = re.match(r'^/([A-Za-z])(?:/(.*)|)$', out)
            # 排除真正的单级目录 /etc /tmp 等：仅当首段是单字母盘符样式才转
            if m and not os.path.isdir(out.replace("\\", "/")):
                out = f"{m.group(1).upper()}:/{m.group(2) or ''}"

    return out.replace("\\", "/")


def _resolve_windows_exe(p: str) -> str:
    """Windows 上若候选不带 .exe 且同目录存在 <候选>.exe，返回带 .exe 的那个。"""
    if os.name == "nt" and p and not p.lower().endswith(".exe"):
        exe = p + ".exe"
        if os.path.isfile(exe):
            return exe
    return p


def find_hermes(cfg=None) -> str:
    """定位 hermes 可执行：WF_HERMES → shutil.which('hermes') → 原值/'hermes' 兜底。

    拿到候选后必须先做原生路径归一（native_path），原因有二：
      1. 原生 Windows Python 的 subprocess 不认 MSYS 路径：调用方常从 bash
         侧把 WF_HERMES 写成 /c/Users/.../venv/Scripts/hermes，直接传给
         subprocess 会抛 WinError/FileNotFoundError，把整条链路静默打断。
      2. Windows 的 venv Scripts/ 目录里通常只有 hermes.exe，没有无扩展名
         的 hermes；候选不带 .exe 且同目录存在 <候选>.exe 时返回带 .exe 的。

    归一后仍不可用（os.path.isfile 失败）才回退 shutil.which('hermes')，
    最后回退到原值兜底。兜底而不报错：调用方（bash 侧）通常自己也有 PATH，
    让错误在真正执行时暴露，错误信息更贴近现场。
    """
    explicit = env("WF_HERMES", "", cfg=cfg)
    if explicit:
        p = _resolve_windows_exe(native_path(explicit))
        if os.path.isfile(p):
            return p

    which = shutil.which("hermes")
    if which:
        p = _resolve_windows_exe(native_path(which))
        if os.path.isfile(p):
            return p

    return explicit or which or "hermes"


# 供 bash 侧调用：python wf_common.py native_path /d/tmp
if __name__ == "__main__":
    import sys

    if len(sys.argv) >= 3 and sys.argv[1] == "native_path":
        print(native_path(sys.argv[2]))
    else:
        print("用法: python wf_common.py native_path <路径>", file=sys.stderr)
        sys.exit(2)
