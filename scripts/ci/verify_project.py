#!/usr/bin/env python3
"""工程一致性静态校验（纯标准库，无第三方依赖）。

为什么需要它
------------
这个工程有三处「手工同步」的脆弱点，任一处不同步都会产出
**能编译、能安装、但装上去是废的** 包（键盘读不到配置 / 键盘不出现）：

1. App Group 字符串硬编码在 `Shared/JevModel.swift`，同时又要写进两份 entitlements。
   不一致 → App 往一个自己没权限的 suite 写配置，键盘永远读不到。
2. `project.pbxproj` 用的是显式 `PBXFileReference`（不是 Xcode 16 的
   FileSystemSynchronizedRootGroup），新增 .swift 必须手工登记 6 处。
   漏登记 → `cannot find 'X' in scope`，而磁盘上文件明明存在，肉眼极难发现。
3. `Info.plist` / `*.entitlements` 由 `xcodegen` 从 `project.yml` 生成，
   手改生成物会被下次 `xcodegen generate` 悄悄冲掉。

这些都不需要 Xcode 就能查出来，所以放在 CI 最前面跑（ubuntu 上几秒完事）。

用法
----
    python3 scripts/ci/verify_project.py            # 仓库根目录下
    python3 scripts/ci/verify_project.py --root /path/to/repo

退出码：有 error 时非 0；只有 warning 时仍为 0。
"""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------- 输出工具

ERRORS: list[str] = []
WARNINGS: list[str] = []
PASSED = 0


def ok(msg: str) -> None:
    global PASSED
    PASSED += 1
    print(f"  \u2705 {msg}")


def err(msg: str) -> None:
    ERRORS.append(msg)
    print(f"  \u274c {msg}")
    # 同时发 GitHub annotation：Actions 日志要登录才能看，
    # annotation 是唯一匿名可读的通道（curl api.github.com/.../check-runs/<id>/annotations）。
    print(f"::error title=工程一致性::{msg}")


def warn(msg: str) -> None:
    WARNINGS.append(msg)
    print(f"  \u26a0\ufe0f  {msg}")


def head(msg: str) -> None:
    print(f"\n=== {msg} ===")


# ---------------------------------------------------------------- 常量

SHARED_DIR = "Shared"
# target 名 -> 允许出现在哪里（用于「磁盘文件必须被登记」的期望集合）
EXPECTED_SOURCES_FALLBACK = {
    "JevJarvis": ["App/Sources", SHARED_DIR],
    "JevKeyboard": ["Keyboard/Sources", SHARED_DIR],
    "JevJarvisUITests": ["UITests"],
}
UUID = r"[0-9A-Fa-f]{24}"


# ---------------------------------------------------------------- pbxproj 解析


def split_pbxproj_section(text: str, section: str) -> str:
    """取出 `/* Begin X section */` 到 `/* End X section */` 之间的内容。"""
    m = re.search(
        rf"/\* Begin {re.escape(section)} section \*/(.*?)/\* End {re.escape(section)} section \*/",
        text,
        re.S,
    )
    return m.group(1) if m else ""


def split_blocks(section_text: str) -> dict[str, str]:
    """把 section 切成 {uuid: block_text}。

    条目形态固定为:
        <UUID> /* comment */ = {
            ...body...
        };
    comment 也可能是 `JevJarvis */ = {` 之外的形式，这里只锚定 UUID + `= {`。
    """
    blocks: dict[str, str] = {}
    pattern = re.compile(rf"^\s*({UUID})\b[^\n]*?=\s*\{{", re.M)
    matches = list(pattern.finditer(section_text))
    for i, m in enumerate(matches):
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(section_text)
        blocks[m.group(1)] = section_text[start:end]
    return blocks


def parse_targets(pbxproj: str) -> dict[str, list[str]]:
    """{target 名: [该 target 的 Sources build phase UUID]}"""
    native = split_blocks(split_pbxproj_section(pbxproj, "PBXNativeTarget"))
    result: dict[str, list[str]] = {}
    for _uuid, body in native.items():
        name = re.search(r"^\s*name\s*=\s*([^;]+);", body, re.M)
        if not name:
            continue
        target_name = name.group(1).strip().strip('"')
        phases_block = re.search(r"buildPhases\s*=\s*\((.*?)\);", body, re.S)
        phases = re.findall(rf"({UUID})", phases_block.group(1)) if phases_block else []
        result[target_name] = phases
    return result


def parse_source_phases(pbxproj: str) -> dict[str, list[str]]:
    """{sources phase UUID: [被编译的 .swift 文件名]}"""
    phases = split_blocks(split_pbxproj_section(pbxproj, "PBXSourcesBuildPhase"))
    result: dict[str, list[str]] = {}
    for uuid, body in phases.items():
        files_block = re.search(r"files\s*=\s*\((.*?)\);", body, re.S)
        names = re.findall(r"/\* ([^\s]+\.swift) in Sources \*/", files_block.group(1)) if files_block else []
        result[uuid] = names
    return result


def registered_sources_by_target(pbxproj: str) -> dict[str, set[str]]:
    targets = parse_targets(pbxproj)
    phases = parse_source_phases(pbxproj)
    out: dict[str, set[str]] = {}
    for target, phase_uuids in targets.items():
        files: set[str] = set()
        for p in phase_uuids:
            files.update(phases.get(p, []))
        out[target] = files
    return out


# ---------------------------------------------------------------- project.yml 解析


def parse_project_yml_targets(yml: str) -> dict[str, list[str]]:
    """从 project.yml 抠出 {target: [sources 里的 path]}。

    只用几条固定形态的正则，不引 PyYAML —— CI 上系统 python3 未必有它，
    而为了一个静态检查去装依赖不值得。
    """
    # 注意：必须停在下一个顶层 key（`^\S`，例如 `schemes:`）之前。
    # 若用 `\Z` 收尾，`schemes:` 下的同名条目（JevJarvis / JevKeyboard）会覆盖
    # 掉 targets 里的真身，解析出空 sources —— 检查会被静默跳过，比报错还危险。
    m = re.search(r"^targets:\s*$(.*?)(?=^\S|\Z)", yml, re.M | re.S)
    if not m:
        return {}
    body = m.group(1)
    # 顶层 target 缩进 2 空格，到下一个同级 key 或结尾为止
    chunks = re.split(r"^(?=  \S)", body, flags=re.M)
    result: dict[str, list[str]] = {}
    for chunk in chunks:
        name_m = re.match(r"^  (\w+):\s*$", chunk, re.M)
        if not name_m:
            continue
        src_m = re.search(r"^\s+sources:\s*$(.*?)(?=^\s{4}\w|\Z)", chunk, re.M | re.S)
        paths: list[str] = []
        if src_m:
            paths = re.findall(r"-\s*path:\s*([^\s#]+)", src_m.group(1))
        # 防御：同名条目重复出现时，绝不用空列表覆盖已有结果
        if name_m.group(1) in result and not paths:
            continue
        result[name_m.group(1)] = paths
    return result


def swift_files_under(root: Path, rel: str) -> set[str]:
    d = root / rel
    if not d.is_dir():
        return set()
    return {p.name for p in d.rglob("*.swift")}


# ---------------------------------------------------------------- 各项检查


def check_app_group(root: Path) -> None:
    head("App Group 三方一致（Swift \u2194 两份 entitlements）")

    swift_src = root / "Shared/JevModel.swift"
    if not swift_src.is_file():
        err("找不到 Shared/JevModel.swift")
        return
    m = re.search(r'appGroupID\s*=\s*"([^"]+)"', swift_src.read_text(encoding="utf-8"))
    if not m:
        err("Shared/JevModel.swift 里找不到 `appGroupID = \"...\"` —— 解析规则可能已失效")
        return
    swift_group = m.group(1)
    ok(f"Swift 侧 appGroupID = {swift_group}")

    if not swift_group.startswith("group."):
        err(f"App Group 必须以 group. 开头，实际 {swift_group!r}")

    for rel, label in [
        ("App/JevJarvis.entitlements", "App"),
        ("Keyboard/JevKeyboard.entitlements", "键盘扩展"),
    ]:
        p = root / rel
        if not p.is_file():
            err(f"找不到 {rel}")
            continue
        try:
            data = plistlib.loads(p.read_bytes())
        except Exception as exc:  # noqa: BLE001
            err(f"{rel} 不是合法 plist: {exc}")
            continue
        groups = data.get("com.apple.security.application-groups") or []
        if not groups:
            err(f"{rel} 没有申请任何 application-groups —— 键盘与 App 将各拿一个私有容器")
            continue
        if groups[0] != swift_group:
            err(f"{label} entitlements 的 App Group = {groups[0]}，与 Swift 的 {swift_group} 不一致")
        else:
            ok(f"{label} entitlements App Group 一致（{groups[0]}）")


def check_bundle_ids(root: Path, expected_app: str | None) -> None:
    head("Bundle ID 结构一致（pbxproj \u2194 project.yml）")

    pbx = root / "JevJarvis.xcodeproj/project.pbxproj"
    if not pbx.is_file():
        err("找不到 JevJarvis.xcodeproj/project.pbxproj")
        return
    text = pbx.read_text(encoding="utf-8", errors="replace")
    found = set(re.findall(r"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);", text))
    found = {v.strip().strip('"') for v in found}
    if not found:
        err("pbxproj 里没找到任何 PRODUCT_BUNDLE_IDENTIFIER")
        return
    ok(f"pbxproj 里的 Bundle ID 集合：{', '.join(sorted(found))}")

    app = expected_app
    if many := {b for b in found if not b.endswith((".keyboard", ".uitests"))}:
        candidates = sorted(many)
        if len(candidates) > 1:
            warn(f"多个候选宿主 Bundle ID（{candidates}），按排序取第一个")
        if app is None:
            app = candidates[0]

    if app is None:
        err("推导不出宿主 App 的 Bundle ID")
        return

    for suffix, label in [(".keyboard", "键盘扩展"), (".uitests", "UI 测试")]:
        want = app + suffix
        if want not in found:
            err(f"{label} 的 Bundle ID 应为 {want}，pbxproj 里没有（实际有 {sorted(found)}）")
        else:
            ok(f"{label} Bundle ID 正确：{want}")

    yml = (root / "project.yml").read_text(encoding="utf-8")
    for want in [app, app + ".keyboard", app + ".uitests"]:
        if f"PRODUCT_BUNDLE_IDENTIFIER: {want}" not in yml:
            err(f"project.yml 里缺少 `PRODUCT_BUNDLE_IDENTIFIER: {want}` —— 下次 xcodegen generate 会把它冲掉")
    if all(f"PRODUCT_BUNDLE_IDENTIFIER: {w}" in yml for w in [app, app + ".keyboard", app + ".uitests"]):
        ok("project.yml 与 pbxproj 的 Bundle ID 同步")


def check_version_sync(root: Path) -> None:
    head("版本号一致（project.yml \u2194 pbxproj）")

    yml = (root / "project.yml").read_text(encoding="utf-8")

    def yml_value(key: str) -> str | None:
        m = re.search(rf"^\s*{key}:\s*\"?([^\"\n#]+)\"?\s*$", yml, re.M)
        return m.group(1).strip() if m else None

    marketing = yml_value("MARKETING_VERSION")
    build_no = yml_value("CURRENT_PROJECT_VERSION")

    if not marketing or not build_no:
        err("project.yml 里缺 MARKETING_VERSION 或 CURRENT_PROJECT_VERSION")
        return
    ok(f"project.yml 版本：{marketing} ({build_no})")

    pbx = (root / "JevJarvis.xcodeproj/project.pbxproj").read_text(encoding="utf-8", errors="replace")
    for key, want in [("MARKETING_VERSION", marketing), ("CURRENT_PROJECT_VERSION", build_no)]:
        got = set(re.findall(rf"{key}\s*=\s*([^;]+);", pbx))
        got = {v.strip().strip('"') for v in got}
        if got != {want}:
            err(f"pbxproj 的 {key} 是 {sorted(got)}，与 project.yml 的 {want} 不一致")
        else:
            ok(f"pbxproj {key} = {want}")


def check_sources_registered(root: Path) -> None:
    head("源文件登记（磁盘 \u2194 pbxproj，防 cannot find in scope）")

    pbx_path = root / "JevJarvis.xcodeproj/project.pbxproj"
    if not pbx_path.is_file():
        err("找不到 project.pbxproj")
        return
    pbx = pbx_path.read_text(encoding="utf-8", errors="replace")

    yml_targets = parse_project_yml_targets((root / "project.yml").read_text(encoding="utf-8"))
    if yml_targets:
        ok(f"从 project.yml 解析出 {len(yml_targets)} 个 target：{', '.join(sorted(yml_targets))}")
    else:
        warn("project.yml 解析不出 target，回退到内置映射表")
        yml_targets = EXPECTED_SOURCES_FALLBACK

    registered = registered_sources_by_target(pbx)
    if not registered:
        err("pbxproj 解析不出任何 target 的 Sources —— 解析规则可能已失效（pbxproj 格式变了？）")
        return

    all_registered: set[str] = set()
    for target, files in registered.items():
        all_registered |= files
        print(f"      {target}: 登记 {len(files)} 个源文件")

    # ① 磁盘 -> pbxproj：每个源文件都必须在它所属 target 里被登记
    for target, paths in yml_targets.items():
        if target not in registered:
            warn(f"pbxproj 里没有 target `{target}`（project.yml 里有）")
            continue
        expected: set[str] = set()
        for rel in paths:
            expected |= swift_files_under(root, rel)
        if not expected:
            # 静默跳过会让整个检查变成假绿，这里必须显式告警
            warn(
                f"target `{target}` 在 project.yml 里声明了 sources {paths}，"
                f"但一个 .swift 都没解析出来 —— 解析规则可能已失效，本 target 未被校验"
            )
            continue
        missing = expected - registered[target]
        if missing:
            err(
                f"target `{target}` 漏登记 {sorted(missing)} —— "
                f"磁盘上有但没进 Sources build phase，编译时会报 cannot find 'X' in scope。"
                f"（pbxproj 用显式 PBXFileReference，必须手工补 PBXBuildFile/PBXFileReference/group/Sources 共 6 处）"
            )
        else:
            ok(f"target `{target}`：磁盘 {len(expected)} 个源文件全部已登记")

    # ② pbxproj -> 磁盘：登记的不能是幽灵文件。
    # 先把磁盘上的 .swift 名字收一遍，避免对每个登记项做一次全仓 rglob。
    on_disk = {p.name for p in root.rglob("*.swift") if not any(s in p.parts for s in SKIP_DIRS)}
    ghost = {n for n in all_registered if n not in on_disk}
    if ghost:
        err(f"pbxproj 登记了磁盘上不存在的文件：{sorted(ghost)}")
    else:
        ok(f"pbxproj 登记的 {len(all_registered)} 个源文件在磁盘上均存在")


def check_infoplist(root: Path) -> None:
    head("Info.plist 关键键（键盘能弹出来 + 不崩宿主的前提）")

    kb_path = root / "Keyboard/Info.plist"
    if not kb_path.is_file():
        err("找不到 Keyboard/Info.plist")
        return
    try:
        kb = plistlib.loads(kb_path.read_bytes())
    except Exception as exc:  # noqa: BLE001
        err(f"Keyboard/Info.plist 不是合法 plist: {exc}")
        return

    ext = kb.get("NSExtension") or {}
    if ext.get("NSExtensionPointIdentifier") != "com.apple.keyboard-service":
        err("Keyboard/Info.plist 的 NSExtensionPointIdentifier 不是 com.apple.keyboard-service")
    else:
        ok("NSExtensionPointIdentifier = com.apple.keyboard-service")

    principal = ext.get("NSExtensionPrincipalClass", "")
    if "KeyboardViewController" not in principal:
        err(f"NSExtensionPrincipalClass 应指向 KeyboardViewController，实际 {principal!r}")
    else:
        ok(f"NSExtensionPrincipalClass = {principal}")

    attrs = ext.get("NSExtensionAttributes") or {}
    lang = attrs.get("PrimaryLanguage")
    if not lang:
        err("NSExtensionAttributes 缺 PrimaryLanguage —— 键盘弹起时会让宿主直接崩")
    elif lang == "zh-Hans":
        err(
            "PrimaryLanguage 是 zh-Hans。审核环境（英文系统/听写语言未启用）查 zh-Hans 的听写语言拿到 nil，"
            "系统 TextInput 会以 setObject:forKey: 传 nil 把宿主 App 崩掉。必须改 en-US。"
        )
    else:
        ok(f"PrimaryLanguage = {lang}（规避 zh-Hans 听写元数据缺失导致宿主崩溃）")

    if attrs.get("RequestsOpenAccess") is not True:
        warn("RequestsOpenAccess 不是 true —— 键盘拿不到网络与剪贴板权限")
    else:
        ok("RequestsOpenAccess = true")

    if kb.get("CFBundleShortVersionString") != "$(MARKETING_VERSION)":
        err("Keyboard/Info.plist 的 CFBundleShortVersionString 不是 $(MARKETING_VERSION)，版本会漂移")
    if kb.get("CFBundleVersion") != "$(CURRENT_PROJECT_VERSION)":
        err("Keyboard/Info.plist 的 CFBundleVersion 不是 $(CURRENT_PROJECT_VERSION)")
    if kb.get("CFBundlePackageType") != "XPC!":
        err(f"键盘扩展 CFBundlePackageType 应为 XPC!，实际 {kb.get('CFBundlePackageType')!r}")
    if kb.get("CFBundleShortVersionString") == "$(MARKETING_VERSION)" and kb.get(
        "CFBundleVersion"
    ) == "$(CURRENT_PROJECT_VERSION)":
        ok("键盘版本号走构建设置变量，不会与 App 漂移")

    app_path = root / "App/Info.plist"
    if not app_path.is_file():
        err("找不到 App/Info.plist")
        return
    try:
        app = plistlib.loads(app_path.read_bytes())
    except Exception as exc:  # noqa: BLE001
        err(f"App/Info.plist 不是合法 plist: {exc}")
        return
    if app.get("CFBundlePackageType") != "APPL":
        err(f"宿主 App CFBundlePackageType 应为 APPL，实际 {app.get('CFBundlePackageType')!r}")
    else:
        ok("宿主 App CFBundlePackageType = APPL")
    if "ITSAppUsesNonExemptEncryption" not in app:
        warn("App/Info.plist 缺 ITSAppUsesNonExemptEncryption —— 每次上架都要回答加密合规问题")


SECRET_PATTERNS = [
    (re.compile(r"\bsk-or-v1-[A-Za-z0-9]{32,}"), "OpenRouter key"),
    (re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"), "OpenAI 风格 key"),
    (re.compile(r"\bsk-ant-[A-Za-z0-9\-_]{20,}"), "Anthropic key"),
    (re.compile(r"\bAIza[A-Za-z0-9\-_]{30,}"), "Google API key"),
]

SCAN_SUFFIXES = {".swift", ".py", ".json", ".plist", ".yml", ".yaml", ".sh", ".txt", ".md"}
SKIP_DIRS = {".git", "build", "DerivedData", ".venv", "node_modules", ".build"}


def check_no_secrets(root: Path) -> None:
    head("密钥泄漏扫描（AGENTS.md: 不得提交 API key）")
    hits: list[str] = []
    scanned = 0
    for p in root.rglob("*"):
        if not p.is_file() or p.suffix.lower() not in SCAN_SUFFIXES:
            continue
        if any(part in SKIP_DIRS for part in p.relative_to(root).parts):
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        scanned += 1
        for pat, label in SECRET_PATTERNS:
            for m in pat.finditer(text):
                line = text[: m.start()].count("\n") + 1
                hits.append(f"{p.relative_to(root)}:{line} 疑似 {label}: {m.group(0)[:12]}...")
    if hits:
        for h in hits:
            err(f"疑似硬编码密钥 -> {h}")
    else:
        ok(f"扫描 {scanned} 个文件，未发现硬编码密钥")


# ---------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser(description="工程一致性静态校验")
    ap.add_argument("--root", default=None, help="仓库根目录，默认按脚本位置推导")
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parents[2]
    print(f"仓库根目录：{root}")
    if not (root / "project.yml").is_file():
        print(f"::error title=工程一致性::在 {root} 找不到 project.yml，--root 指错了？")
        return 2

    # 先定 App Group，Bundle ID 检查要复用它
    check_app_group(root)

    m = re.search(
        r"appGroupID\s*=\s*\"group\.([^\"]+)\"",
        (root / "Shared/JevModel.swift").read_text(encoding="utf-8"),
    )
    expected_app = m.group(1) if m else None

    check_bundle_ids(root, expected_app)
    check_version_sync(root)
    check_sources_registered(root)
    check_infoplist(root)
    check_no_secrets(root)

    print("\n" + "=" * 56)
    print(f"通过 {PASSED} 项，警告 {len(WARNINGS)} 项，错误 {len(ERRORS)} 项")
    if ERRORS:
        print("\n需要修的问题：")
        for e in ERRORS:
            print(f"  \u274c {e}")
    if WARNINGS:
        print("\n可以留意的问题：")
        for w in WARNINGS:
            print(f"  \u26a0\ufe0f  {w}")
    print("=" * 56)
    return 1 if ERRORS else 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    except Exception:  # noqa: BLE001
        pass
    sys.exit(main())
