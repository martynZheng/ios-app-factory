#!/bin/bash
# 在模拟器里用演示数据启动 App 截图 + 录一段生长动画，供 Claude 自查界面。输出到 $1。
set -euo pipefail
OUT="$1"; mkdir -p "$OUT"
cd "$(dirname "$0")"
xcodegen generate >/dev/null
DEV=$(xcrun simctl list devices available | grep -E "iPhone Duo" | head -1 | grep -oE "[0-9A-F-]{36}" || true)
if [ -z "$DEV" ]; then DEV=$(xcrun simctl list devices available | grep -E "iPhone 1[5-9]" | head -1 | grep -oE "[0-9A-F-]{36}"); fi
xcrun simctl list devices available | grep "$DEV"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme App -configuration Debug -destination "id=$DEV" \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP=$(find build/dd/Build/Products -maxdepth 2 -name "$APP_NAME.app" -path "*iphonesimulator*" | head -1)
[ -n "$APP" ] || { echo "simulator build failed"; exit 1; }
xcrun simctl boot "$DEV" || true
xcrun simctl bootstatus "$DEV" -b
xcrun simctl install "$DEV" "$APP"
xcrun simctl status_bar "$DEV" override --time "10:02" >/dev/null 2>&1 || true

launch() {
  xcrun simctl terminate "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$DEV" "$BUNDLE_ID" -demo 1 "$@" >/dev/null
}
# iPhone Duo 模拟器有两块屏：1=外屏，3=内屏（合上时内屏是黑的，命令行没法展开）
snap() {
  xcrun simctl io "$DEV" screenshot "$1" >/dev/null 2>&1 || xcrun simctl io "$DEV" screenshot --display=1 "$1" >/dev/null 2>&1 || true
}
shot() { local name="$1"; shift; launch "$@"; sleep 7; snap "$OUT/$name.png"; }

# 生长动画录屏
launch -grow 1
sleep 0.3
xcrun simctl io "$DEV" recordVideo --codec=h264 --display=1 --force "$OUT/grow.mp4" >/dev/null 2>&1 &
REC=$!
sleep 1
if ! kill -0 $REC 2>/dev/null; then
  xcrun simctl io "$DEV" recordVideo --codec=h264 --force "$OUT/grow.mp4" >/dev/null 2>&1 &
  REC=$!
fi
sleep 8
kill -INT $REC 2>/dev/null || true
wait $REC 2>/dev/null || true

shot today
shot today-bottom -scroll 1
shot chapter -chapter 1
shot timeline -tab 1
shot todos -tab 2
xcrun simctl ui "$DEV" appearance dark
shot today-dark-bottom -scroll 1
shot timeline-dark -tab 1
ls -la "$OUT"
