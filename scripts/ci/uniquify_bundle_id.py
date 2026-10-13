#!/usr/bin/env python3
"""把 Bundle ID / App Group 改写成 `<handle>` 专属，避免撞上原作者已占用的 App ID。

为什么需要
----------
App ID 与 App Group 在 Apple 侧是全局唯一的。你 fork 后直接编译，签名时会撞上
原作者已经注册过的 `com.jevchat.jarvis`，报 "identifier is not available"。
所以构建前把仓库里的 Bundle ID 前缀换掉。

关键坑
------
App Group 字符串**硬编码在 `Shared/JevModel.swift`**（`JevStore.appGroupID`），
同时又要写进两份 entitlements。只改 pbxproj 不改 Swift → App 会往一个自己没有
权限的 UserDefaults suite 写配置，键盘永远读不到，包等于废的。
所以这里一次性改全部 6 个文件，改完立刻做一致性断言。

用法
----
    python3 scripts/ci/uniquify_bundle_id.py --handle zx1184781795
    python3 scripts/ci/uniquify_bundle_id.py --handle zx1184781795 --new-base com.foo.jevjarvis
    python3 scripts/ci/uniquify_bundle_id.py --handle x --dry-run
    python3 scripts/ci/uniquify_bundle_id.py --handle x --print-env >> "$GITHUB_ENV"
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# 这些文件里藏着旧 Bundle ID / App Group 字符串
TARGETS = [
    "JevJarvis.xcodeproj/project.pbxproj",
    "project.yml",
    "App/JevJarvis.entitlements",
    "Keyboard/JevKeyboard.entitlements",
    "Shared/JevModel.swift",
    "UITests/AutoLaunchTests.swift",
]


def detect_old_base(root: Path) -> str:
    """从 Swift 里的 appGroupID 反推旧的宿主 Bundle ID。

    这是唯一可信的源头 —— entitlements / pbxproj / project.yml 都可能被手改过，
    而 Swift 里那个常量是键盘实际去要的那个 group。
    """
    src = (root / "Shared/JevModel.swift").read_text(encoding="utf-8")
    m = re.search(r'appGroupID\s*=\s*"group\.([^"]+)"', src)
    if not m:
        raise SystemExit("::error title=改写 Bundle ID::Shared/JevModel.swift 里找不到 appGroupID，无法推断旧 Bundle ID")
    return m.group(1)


def slug(handle: str) -> str:
    """GitHub 用户名 -> 合法的 Bundle ID 片段（小写字母数字）。"""
    s = re.sub(r"[^0-9A-Za-z]", "", handle).lower()
    return s or "dev"


def main() -> int:
    ap = argparse.ArgumentParser(description="改写 Bundle ID 与 App Group")
    ap.add_argument("--handle", required=True, help="GitHub 用户名，用于生成新前缀")
    ap.add_argument("--new-base", default=None, help="直接指定新的宿主 Bundle ID（默认 com.<handle>.jevjarvis）")
    ap.add_argument("--root", default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--print-env", action="store_true", help="把结果按 GITHUB_ENV 格式输出")
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else ROOT
    old_base = detect_old_base(root)
    handle = slug(args.handle)
    new_base = args.new_base or f"com.{handle}.jevjarvis"

    if old_base == new_base:
        print(f"Bundle ID 已经是 {new_base}，无需改写")
        if args.print_env:
            print(f"APP_BUNDLE_ID={new_base}")
            print(f"KB_BUNDLE_ID={new_base}.keyboard")
            print(f"APP_GROUP=group.{new_base}")
        return 0

    print(f"GitHub 用户名 slug : {handle}")
    print(f"旧 Bundle ID       : {old_base}")
    print(f"新 Bundle ID       : {new_base}")
    print(f"（顺带把 group.{old_base} 改成 group.{new_base}）")

    total = 0
    for rel in TARGETS:
        path = root / rel
        if not path.is_file():
            print(f"  -- {rel}: 不存在，跳过")
            continue
        text = path.read_text(encoding="utf-8")
        count = text.count(old_base)
        if count:
            if not args.dry_run:
                path.write_text(text.replace(old_base, new_base), encoding="utf-8")
            total += count
        print(f"  {'~' if args.dry_run else '✓'} {rel}: {count} 处")

    if total == 0:
        print("::error title=改写 Bundle ID::一个匹配都没找到，改写逻辑可能已失效")
        return 1

    if args.dry_run:
        print(f"\n[dry-run] 共会改写 {total} 处")
        return 0

    # ---- 改完立刻断言，失败就停在构建之前（省下 3 分钟编译）----
    src = (root / "Shared/JevModel.swift").read_text(encoding="utf-8")
    swift_group = re.search(r'appGroupID\s*=\s*"([^"]+)"', src)
    ent_group = re.search(
        r"<string>(group\.[^<]+)</string>",
        (root / "App/JevJarvis.entitlements").read_text(encoding="utf-8"),
    )
    kb_group = re.search(
        r"<string>(group\.[^<]+)</string>",
        (root / "Keyboard/JevKeyboard.entitlements").read_text(encoding="utf-8"),
    )
    if not (swift_group and ent_group and kb_group):
        print("::error title=改写 Bundle ID::App Group 字符串提取失败，无法做一致性校验")
        return 1
    groups = {swift_group.group(1), ent_group.group(1), kb_group.group(1)}
    if len(groups) != 1:
        print(f"::error title=改写 Bundle ID::App Group 不一致：Swift={swift_group.group(1)} App={ent_group.group(1)} 键盘={kb_group.group(1)}")
        return 1
    if groups.pop() != f"group.{new_base}":
        print(f"::error title=改写 Bundle ID::App Group 不是预期的 group.{new_base}")
        return 1
    print(f"\n一致性校验通过：三方 App Group 均为 group.{new_base}")

    if args.print_env:
        print(f"APP_BUNDLE_ID={new_base}")
        print(f"KB_BUNDLE_ID={new_base}.keyboard")
        print(f"APP_GROUP=group.{new_base}")
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    except Exception:  # noqa: BLE001
        pass
    sys.exit(main())
