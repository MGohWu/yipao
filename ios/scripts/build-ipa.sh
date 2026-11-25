#!/usr/bin/env bash
# 产出一个**未签名**的 IPA，交给 Sideloadly / AltStore / ESign 之类工具用你自己的证书签。
#
# 用法（在 macOS 上，需装 Xcode 和 xcodegen）：
#     ios/scripts/build-ipa.sh
#
# 可选环境变量：
#     TEAM_ID=ABCDE12345   写入工程（不打进 IPA，但签名身份要一致才省事）
#     BUNDLE_ID=com.x.y    主 App 的 Bundle ID，小组件自动加 .widget
#     APP_GROUP=group.x.y  必须和开发者后台注册的那个 App Group 一致
#     AMAP_KEY=xxxx        高德 Web 服务 key，写进 Info.plist；不传就用苹果 MapKit 算驾车距离
#     OUTPUT=/path/x.ipa   产物路径
#
# 为什么要显式关掉签名：`CODE_SIGNING_ALLOWED=NO` 打出来的 .app 不带 _CodeSignature，
# 重签工具才不会碰到「签名里混着别人的证书」这种半吊子状态。扩展（.appex）也一并是裸的，
# 重签时必须和主 App 用同一张证书、同一个 Team——工具一般会自动处理，但别手动只签主 App。
set -euo pipefail

cd "$(dirname "$0")/.."

OUTPUT="${OUTPUT:-$(pwd)/build/跑跑-iOS-unsigned.ipa}"
SCHEME="LeapControl"
PROJECT="LeapControl.xcodeproj"
ARCHIVE="$(pwd)/build/Paopao.xcarchive"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "缺 xcodegen：brew install xcodegen" >&2
    exit 1
fi

# `set -u` 下必须写 `${X:-}`：这三个都是可选环境变量，CI 里一个都不传，
# 裸写 `${TEAM_ID}` 会以 "TEAM_ID: unbound variable" 直接退出——2026-11-24 就是这么挂的。
if [ -n "${TEAM_ID:-}${BUNDLE_ID:-}${APP_GROUP:-}${AMAP_KEY:-}" ]; then
    args=()
    [ -n "${TEAM_ID:-}" ] && args+=(--team "$TEAM_ID")
    [ -n "${BUNDLE_ID:-}" ] && args+=(--bundle-id "$BUNDLE_ID")
    [ -n "${APP_GROUP:-}" ] && args+=(--app-group "$APP_GROUP")
    [ -n "${AMAP_KEY:-}" ] && args+=(--amap-key "$AMAP_KEY")
    python3 scripts/configure-signing.py "${args[@]}"
    echo
fi

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild archive（不签名）"
rm -rf "$ARCHIVE"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    archive

APP="$ARCHIVE/Products/Applications/LeapControl.app"
if [ ! -d "$APP" ]; then
    echo "没找到 $APP，archive 没产出 App" >&2
    exit 1
fi

# 扩展必须在 PlugIns 里，且和主 App 一起被打进同一个 Payload。
if [ ! -d "$APP/PlugIns/LeapWidget.appex" ]; then
    echo "警告：$APP/PlugIns 里没有 LeapWidget.appex，小组件和灵动岛会整体消失" >&2
fi
# 这两项缺一个，灵动岛就起不来：主 App 的 plist 必须声明支持 Live Activity。
if ! /usr/libexec/PlistBuddy -c "Print :NSSupportsLiveActivities" "$APP/Info.plist" >/dev/null 2>&1; then
    echo "警告：Info.plist 里没有 NSSupportsLiveActivities，灵动岛会不出现" >&2
fi

echo "==> 打包 IPA"
STAGE="$(pwd)/build/ipa-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
( cd "$STAGE" && zip -qry "$OUTPUT" Payload )
rm -rf "$STAGE"

echo
echo "产物：$OUTPUT"
echo "大小：$(du -h "$OUTPUT" | cut -f1)"
echo "SHA-256："
shasum -a 256 "$OUTPUT"
echo
echo "下一步：用你自己的 Apple ID 签这个 IPA（见 SIGNING.md）。"
echo "别解压后只签主 App——扩展、App Group、钥匙串组任何一处没跟上，小组件和灵动岛都会失效。"
