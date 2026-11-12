#!/bin/bash
# 在模拟器里用演示数据启动 App 并截图，供 Claude 自查界面。输出到 $1。
set -euo pipefail
OUT="$1"; mkdir -p "$OUT"
cd "$(dirname "$0")"
xcodegen generate >/dev/null
DEV=$(xcrun simctl list devices available | grep -E "iPhone Duo" | head -1 | grep -oE "[0-9A-F-]{36}" || true)
if [ -z "$DEV" ]; then DEV=$(xcrun simctl list devices available | grep -E "iPhone 1[5-9]" | head -1 | grep -oE "[0-9A-F-]{36}"); fi
xcrun simctl list devices available | grep "$DEV"
set -o pipefail
xcodebuild -project "$APP_NAME.xcodeproj" -scheme App -configuration Debug -destination "id=$DEV" \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" || true
APP=$(find build/dd/Build/Products -maxdepth 2 -name "$APP_NAME.app" -path "*iphonesimulator*" | head -1)
[ -n "$APP" ] || { echo "simulator build failed"; exit 1; }
xcrun simctl boot "$DEV" || true
xcrun simctl bootstatus "$DEV" -b
xcrun simctl install "$DEV" "$APP"
shot() { local name="$1"; shift
  xcrun simctl terminate "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$DEV" "$BUNDLE_ID" -demo 1 "$@" >/dev/null
  sleep 7
  xcrun simctl io "$DEV" screenshot "$OUT/$name.png" >/dev/null; }
shot today
shot chapter -chapter 1
shot timeline -tab 1
shot todos -tab 2
xcrun simctl ui "$DEV" appearance dark
shot today-dark
ls -la "$OUT"
