#!/usr/bin/env python3
"""从 `xcrun simctl list devices available -j` 的输出里挑一台可用的 iPhone 模拟器。

为什么单独成文件而不是写在 workflow 的 `run: |` 里：
YAML 的块标量要求每一行都保持缩进，内嵌的多行 Python 一旦写到第 0 列就会
**提前结束块标量**，后面的代码会被当成 YAML 解析，报出与真实原因毫不相干的错
（实测过：报 "could not find expected ':'"，指向的行完全无辜）。

输入：stdin 收 simctl 的 JSON
输出：stdout 打 `UDID<TAB>机型名`，取第一行
参数：argv[1] = 想要的机型名；留空则取最新 iOS runtime 上的第一台 iPhone

注意 runtime 名形如 `com.apple.CoreSimulator.SimRuntime.iOS-18-0`，
字典序排序会把 iOS-9 排在 iOS-18 后面，所以这里按解析出的版本号数值排序。
"""

from __future__ import annotations

import json
import re
import sys


def runtime_version(key: str) -> tuple[int, ...]:
    """从 runtime 标识里抠出版本号，用于数值排序。"""
    m = re.search(r"iOS[.-](\d+)(?:[.-](\d+))?(?:[.-](\d+))?", key)
    if not m:
        return (0,)
    return tuple(int(g) for g in m.groups() if g is not None)


def main() -> int:
    want = sys.argv[1].strip() if len(sys.argv) > 1 else ""

    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"::error title=模拟器::simctl 输出不是合法 JSON：{exc}", file=sys.stderr)
        return 2

    devices = data.get("devices") or {}
    # runtime 从新到旧
    runtimes = sorted(devices, key=runtime_version, reverse=True)

    if want:
        # 指定机型时跨全部 runtime 找，优先最新
        for runtime in runtimes:
            for dev in devices[runtime]:
                if dev.get("isAvailable") and dev.get("name") == want:
                    print(f"{dev['udid']}\t{dev['name']}")
                    return 0
        print(f"::error title=模拟器::找不到机型 {want!r}，可用机型见日志里的 simctl 列表", file=sys.stderr)
        return 1

    for runtime in runtimes:
        if "iOS" not in runtime:
            continue
        for dev in devices[runtime]:
            if dev.get("isAvailable") and dev.get("name", "").startswith("iPhone"):
                print(f"{dev['udid']}\t{dev['name']}")
                return 0

    print("::error title=模拟器::没有任何可用的 iPhone 模拟器", file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    except Exception:  # noqa: BLE001
        pass
    sys.exit(main())
