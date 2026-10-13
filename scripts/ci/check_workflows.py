#!/usr/bin/env python3
"""workflow 与脚本的自查（本地和 CI 跑同一套）。

查三件在 GitHub 上很难 debug 的事：

1. **YAML 能不能解析。** 块标量里嵌多行脚本时，一旦某行写到第 0 列就会
   提前结束块标量，后面的代码被当成 YAML 解析，报出与真实原因毫不相干的错
   （实测踩过：报 "could not find expected ':'"，指向的行完全无辜）。
2. **每个 `run:` 块是不是合法 bash。** YAML 能解析 ≠ bash 能执行，
   少个 `fi`、多个 `done` 要跑到那一步才知道。
3. **裸标量里有没有 `: `。** `COMMIT_MSG: ci: xxx` 这种写法是合法的 YAML 陷阱：
   冒号后跟空格会被解析成嵌套映射，整份文件解析失败。

顺带把 `scripts/ci/` 下的 .sh / .py 也过一遍语法。

用法：
    python3 scripts/ci/check_workflows.py
    python3 scripts/ci/check_workflows.py --root /path/to/repo

退出码：有任何一项失败即为非 0。
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

FAILED: list[str] = []


def fail(msg: str) -> None:
    FAILED.append(msg)
    print(f"  \u274c {msg}")
    print(f"::error title=workflow 自查::{msg}")


def ok(msg: str) -> None:
    print(f"  \u2705 {msg}")


def head(msg: str) -> None:
    print(f"\n=== {msg} ===")


# ---------------------------------------------------------------- 1. YAML 解析


def check_yaml(files: list[Path]) -> None:
    head("YAML 解析")
    try:
        import yaml  # type: ignore
    except ImportError:
        # PyYAML 在 ubuntu/macOS runner 上都自带，但本机可能没有。
        # 没有就退化成「只查裸标量」这个不需要 yaml 库的检查。
        print("  \u26a0\ufe0f  没装 PyYAML，跳过完整解析（仍会做裸标量检查）")
        return

    for f in files:
        raw = f.read_text(encoding="utf-8")
        try:
            doc = yaml.safe_load(raw)
        except Exception as exc:  # noqa: BLE001
            fail(f"{f.name} YAML 解析失败：{exc}")
            continue
        jobs = list((doc.get("jobs") or {}).keys())
        # PyYAML 按 YAML 1.1 把 `on:` 解析成布尔 True，这里两种都认
        triggers = list((doc.get(True) or doc.get("on") or {}).keys())
        ok(f"{f.name}  触发={triggers}  任务={jobs}")


# ---------------------------------------------------------------- 2. 裸标量陷阱


def check_plain_scalars(files: list[Path]) -> None:
    head("裸标量陷阱（值里含 ': ' 会被当成嵌套映射）")
    hits = 0
    for f in files:
        lines = f.read_text(encoding="utf-8").split("\n")
        in_block = False
        block_indent = 0
        for i, line in enumerate(lines, 1):
            stripped = line.strip()
            if in_block:
                if not stripped:
                    continue
                if len(line) - len(line.lstrip()) > block_indent:
                    continue
                in_block = False
            if re.match(r"^\s*(run|script):\s*\|", line):
                block_indent = len(line) - len(line.lstrip())
                in_block = True
                continue
            if stripped.startswith("#"):
                continue
            m = re.match(r"^\s*[A-Za-z_][\w.\-]*:\s+([^\"'|>\[\{].*)$", line)
            if m and re.search(r":\s", m.group(1)):
                hits += 1
                fail(f"{f.name}:{i} 裸标量含 ': ' -> {stripped[:70]}  （给整个值加引号）")
    if not hits:
        ok("未发现裸标量陷阱")


# ---------------------------------------------------------------- 3. run 块语法


def extract_run_blocks(text: str) -> list[tuple[int, str]]:
    """返回 [(起始行号, 脚本内容)]。"""
    lines = text.split("\n")
    blocks: list[tuple[int, str]] = []
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)-?\s*run:\s*(.*)$", lines[i])
        if not m:
            i += 1
            continue
        indent = len(lines[i]) - len(lines[i].lstrip())
        rest = m.group(2).strip()
        if rest in ("|", "|-", ">", ">-"):
            body: list[str] = []
            j = i + 1
            while j < len(lines):
                l = lines[j]
                if l.strip() and (len(l) - len(l.lstrip())) <= indent:
                    break
                body.append(l)
                j += 1
            nonempty = [l for l in body if l.strip()]
            strip = min((len(l) - len(l.lstrip()) for l in nonempty), default=0)
            script = "\n".join(l[strip:] if len(l) >= strip else l for l in body)
            blocks.append((i + 1, script))
            i = j
        elif rest:
            blocks.append((i + 1, rest))
            i += 1
        else:
            i += 1
    return blocks


def check_run_blocks(files: list[Path]) -> None:
    head("run 块 bash 语法")
    total = 0
    bad = 0
    for f in files:
        for lineno, script in extract_run_blocks(f.read_text(encoding="utf-8")):
            total += 1
            with tempfile.NamedTemporaryFile(
                "w", suffix=".sh", delete=False, encoding="utf-8"
            ) as tf:
                tf.write(script)
                path = tf.name
            try:
                r = subprocess.run(
                    ["bash", "-n", path], capture_output=True, text=True
                )
            except FileNotFoundError:
                print("  \u26a0\ufe0f  找不到 bash，跳过 run 块检查")
                os.unlink(path)
                return
            if r.returncode != 0:
                bad += 1
                fail(f"{f.name}:{lineno} run 块语法错误\n     {r.stderr.strip()}")
            os.unlink(path)
    if bad == 0:
        ok(f"{total} 个 run 块语法均正确")


# ---------------------------------------------------------------- 4. 脚本语法


def check_scripts(root: Path) -> None:
    head("scripts/ci 语法")
    sh_dir = root / "scripts/ci"
    if not sh_dir.is_dir():
        print("  \u26a0\ufe0f  没有 scripts/ci 目录，跳过")
        return

    for f in sorted(sh_dir.glob("*.sh")):
        r = subprocess.run(["bash", "-n", str(f)], capture_output=True, text=True)
        if r.returncode:
            fail(f"{f.name} bash 语法错误：{r.stderr.strip()}")
        else:
            ok(f"{f.name}")

    for f in sorted(sh_dir.glob("*.py")):
        src = f.read_text(encoding="utf-8")
        try:
            # 用 ast 而不是 py_compile：后者会在仓库里留 __pycache__
            import ast

            ast.parse(src, str(f))
        except SyntaxError as exc:
            fail(f"{f.name} python 语法错误：{exc}")
        else:
            ok(f"{f.name}")


# ---------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser(description="workflow 与脚本自查")
    ap.add_argument("--root", default=None)
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parents[2]
    wf_dir = root / ".github/workflows"
    files = sorted(wf_dir.glob("*.yml")) + sorted(wf_dir.glob("*.yaml"))
    print(f"仓库根目录：{root}")
    print(f"找到 {len(files)} 个 workflow 文件")
    if not files:
        print("::error title=workflow 自查::一个 workflow 都没找到")
        return 2

    check_yaml(files)
    check_plain_scalars(files)
    check_run_blocks(files)
    check_scripts(root)

    print("\n" + "=" * 56)
    if FAILED:
        print(f"失败 {len(FAILED)} 项：")
        for m in FAILED:
            print(f"  \u274c {m.splitlines()[0]}")
        print("=" * 56)
        return 1
    print("全部通过")
    print("=" * 56)
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    except Exception:  # noqa: BLE001
        pass
    sys.exit(main())
