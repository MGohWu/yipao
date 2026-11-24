#!/usr/bin/env python3
"""把整个工程的签名身份一次性对齐：Team ID / Bundle ID / App Group / 钥匙串共享组。

为什么需要一个脚本：这四样东西散在 **6 个文件**里，而且必须逐字一致——

    project.yml                          Team ID、两个 target 的 Bundle ID
    LeapControl/LeapControl.entitlements  App Group、钥匙串共享组
    LeapWidget/LeapWidget.entitlements    同上（必须与主 App 完全相同）
    LeapControl/Info.plist                YPAppGroup（运行时读的那份）
    LeapWidget/Info.plist                 同上（扩展进程的 Bundle.main 是 appex）
    LeapControl/Shared/VehicleSnapshot.swift  两处都没配时的兜底常量

漏掉任何一处，症状都是**静默的**：要么装不上（profile 与 entitlement 不匹配），
要么装上了但桌面小组件永远是占位数据、锁屏控件按下去没反应、灵动岛不出现——
而 App 本体一切正常，很容易被当成「小组件坏了」。

用法：
    python3 scripts/configure-signing.py --team ABCDE12345 \\
        --bundle-id com.example.yipao --app-group group.com.example.yipao

只传部分参数时，其余项保持当前值不变。加 --dry-run 只打印将要改什么。
"""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent

PROJECT_YML = IOS / "project.yml"
APP_ENTITLEMENTS = IOS / "LeapControl" / "LeapControl.entitlements"
WIDGET_ENTITLEMENTS = IOS / "LeapWidget" / "LeapWidget.entitlements"
APP_INFO = IOS / "LeapControl" / "Info.plist"
WIDGET_INFO = IOS / "LeapWidget" / "Info.plist"
SNAPSHOT_SWIFT = IOS / "LeapControl" / "Shared" / "VehicleSnapshot.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, text: str, dry_run: bool) -> None:
    if dry_run:
        return
    # newline="" 保住原文件的换行风格，避免整份文件被改写。
    with path.open("w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def current_bundle_id(text: str) -> str:
    match = re.search(r"PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", text)
    if not match:
        sys.exit("project.yml 里找不到 PRODUCT_BUNDLE_IDENTIFIER")
    value = match.group(1)
    return value[: -len(".widget")] if value.endswith(".widget") else value


def current_app_group(text: str) -> str:
    match = re.search(r'<key>YPAppGroup</key>\s*<string>([^<]*)</string>', text)
    if not match:
        sys.exit("Info.plist 里找不到 YPAppGroup")
    return match.group(1)


def current_keychain_group(text: str) -> str:
    match = re.search(
        r"<key>keychain-access-groups</key>\s*<array>\s*<string>([^<]*)</string>", text
    )
    return match.group(1) if match else ""


def keychain_group_for(team: str | None, existing: str, bundle_id: str) -> str:
    """钥匙串共享组写成完整值，不用 `$(AppIdentifierPrefix)`。

    重签工具（全能签、Sideloadly 之类）不一定展开这个构建期变量，留着它签名会报错，
    或者 App 与小组件各读各的登录态。所以这里的优先级是：
    本次给了 Team → 用 Team；没给但现有值里已经带 Team 前缀 → 沿用那个前缀；
    两样都没有才退回变量形式（只有 Xcode 直接编译的场景）。
    """
    if team:
        return f"{team}.{bundle_id}"
    match = re.match(r"^([A-Z0-9]{10})\.", existing)
    if match:
        return f"{match.group(1)}.{bundle_id}"
    return "$(AppIdentifierPrefix)" + bundle_id


def replace_entitlement_array(text: str, key: str, value: str) -> str:
    pattern = re.compile(
        r"(<key>" + re.escape(key) + r"</key>\s*<array>\s*<string>)[^<]*(</string>)"
    )
    new_text, count = pattern.subn(lambda m: m.group(1) + value + m.group(2), text)
    if count == 0:
        sys.exit(f"entitlements 里找不到 {key} 那一项")
    return new_text


def replace_plist_string(text: str, key: str, value: str) -> str:
    pattern = re.compile(
        r"(<key>" + re.escape(key) + r"</key>\s*<string>)[^<]*(</string>)"
    )
    new_text, count = pattern.subn(lambda m: m.group(1) + value + m.group(2), text)
    if count == 0:
        sys.exit(f"plist 里找不到 {key} 那一项")
    return new_text


def main() -> int:
    parser = argparse.ArgumentParser(description="对齐工程里的签名配置")
    parser.add_argument("--team", help="Apple Team ID（10 位），留空表示不改")
    parser.add_argument("--bundle-id", help="主 App 的 Bundle ID，小组件自动加 .widget")
    parser.add_argument("--app-group", help="App Group 标识，形如 group.com.example.yipao")
    parser.add_argument(
        "--amap-key",
        help="高德 Web 服务 key（只写进主 App 的 Info.plist）。传空串表示清掉、退回苹果路线",
    )
    parser.add_argument("--dry-run", action="store_true", help="只打印，不落盘")
    args = parser.parse_args()

    project = read(PROJECT_YML)
    app_info = read(APP_INFO)

    bundle_id = args.bundle_id or current_bundle_id(project)
    app_group = args.app_group or current_app_group(app_info)
    team = args.team

    widget_bundle_id = bundle_id + ".widget"
    tests_bundle_id = bundle_id + ".tests"
    keychain_group = keychain_group_for(
        team, current_keychain_group(read(APP_ENTITLEMENTS)), bundle_id
    )

    if not app_group.startswith("group."):
        sys.exit("App Group 必须以 group. 开头（例如 group.com.example.yipao）")
    if bundle_id.count(".") < 2:
        sys.exit("Bundle ID 至少要有两段（例如 com.example.yipao）")

    print(f"Team ID       : {team or '(不改)'}")
    print(f"主 App        : {bundle_id}")
    print(f"小组件        : {widget_bundle_id}")
    print(f"App Group     : {app_group}")
    print(f"钥匙串共享组  : {keychain_group}")
    print()

    # 1. project.yml：Team ID 与三个 Bundle ID
    if team:
        project = re.sub(
            r'(DEVELOPMENT_TEAM:\s*)"?[^"\n]*"?',
            lambda m: m.group(1) + '"' + team + '"',
            project,
        )
    old_bundle = current_bundle_id(project)
    for old, new in [
        (old_bundle + ".widget", widget_bundle_id),
        (old_bundle + ".tests", tests_bundle_id),
        (old_bundle, bundle_id),
        # bundleIdPrefix 只影响 xcodegen 自动派生的默认值，跟着改保持一致
        ("bundleIdPrefix: " + old_bundle.rsplit(".", 1)[0],
         "bundleIdPrefix: " + bundle_id.rsplit(".", 1)[0]),
    ]:
        project = project.replace(old, new)
    write(PROJECT_YML, project, args.dry_run)

    # 2. 两份 entitlements：App Group + 钥匙串共享组，必须完全一致
    for path in (APP_ENTITLEMENTS, WIDGET_ENTITLEMENTS):
        text = read(path)
        text = replace_entitlement_array(text, "com.apple.security.application-groups", app_group)
        text = replace_entitlement_array(text, "keychain-access-groups", keychain_group)
        write(path, text, args.dry_run)

    # 3. 两份 Info.plist：运行时读的 YPAppGroup
    for path in (APP_INFO, WIDGET_INFO):
        text = read(path)
        write(path, replace_plist_string(text, "YPAppGroup", app_group), args.dry_run)

    # 4. Swift 里的兜底常量
    swift = read(SNAPSHOT_SWIFT)
    swift = re.sub(r'return "group\.[^"]*"', f'return "{app_group}"', swift)
    write(SNAPSHOT_SWIFT, swift, args.dry_run)

    # 5. 高德 Web 服务 key（只写主 App）：决定「驾车距离」问谁要，见 DrivingRouteService。
    #    不打到 stdout 上——CI 日志是公开的，key 露出去等于送人。
    if args.amap_key is not None:
        amap_key = args.amap_key.strip()
        app_info = replace_plist_string(read(APP_INFO), "AMapWebKey", amap_key)
        write(APP_INFO, app_info, args.dry_run)
        if amap_key:
            print(f"高德 key      : {amap_key[:4]}…（{len(amap_key)} 位，已写入主 App 的 Info.plist）")
        else:
            print("高德 key      : 已清空（驾车距离退回苹果 MapKit）")
        print()

    # 校验：两个 plist 必须还能解析，三处 App Group 必须逐字相同
    if not args.dry_run:
        for path in (APP_INFO, WIDGET_INFO, APP_ENTITLEMENTS, WIDGET_ENTITLEMENTS):
            with path.open("rb") as handle:
                plistlib.load(handle)
        groups = {
            p.name: re.search(r'<key>YPAppGroup</key>\s*<string>([^<]*)</string>', read(p)).group(1)
            for p in (APP_INFO, WIDGET_INFO)
        }
        ent_groups = {
            p.name: re.search(
                r"<key>com.apple.security.application-groups</key>\s*<array>\s*<string>([^<]*)</string>",
                read(p),
            ).group(1)
            for p in (APP_ENTITLEMENTS, WIDGET_ENTITLEMENTS)
        }
        if len(set(groups.values()) | set(ent_groups.values())) != 1:
            sys.exit(f"App Group 不一致：{groups} / {ent_groups}")
        keychains = {p.name: current_keychain_group(read(p))
                     for p in (APP_ENTITLEMENTS, WIDGET_ENTITLEMENTS)}
        if len(set(keychains.values())) != 1:
            sys.exit(f"钥匙串共享组不一致：{keychains}")
        print("已写入，四个 plist 都能解析，App Group 四处逐字一致，钥匙串共享组两份一致。")
        print()
        print("接下来：")
        print("  1) 开发者后台 App Groups 里注册 " + app_group)
        print(f"  2) 两个 App ID（{bundle_id} / {widget_bundle_id}）都勾上这个 App Group")
        print(f"     和 Keychain Sharing（共享组 {keychain_group}）")
        print("  3) xcodegen generate 后重新编译")
    else:
        print("--dry-run：没有写任何文件。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
