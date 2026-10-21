#!/bin/bash
# Builds AirBar.app and the airbar CLI, and zips them for a release.
#   scripts/build-app.sh            universal (arm64 + x86_64) release build into dist/
#   scripts/build-app.sh --native   faster build for this Mac's architecture only
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
ARCHS=(--arch arm64 --arch x86_64)
[ "${1:-}" = "--native" ] && ARCHS=()

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product AirBarApp
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product airbar
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

DIST=dist
APP="$DIST/AirBar.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AirBarApp" "$APP/Contents/MacOS/AirBar"
cp "$BIN/airbar" "$DIST/airbar"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AirBar</string>
  <key>CFBundleDisplayName</key><string>AirBar</string>
  <key>CFBundleIdentifier</key><string>io.github.subham12r.airbar</string>
  <key>CFBundleExecutable</key><string>AirBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with Hitachi.</string>
</dict></plist>
PL

codesign --force --sign - "$APP" "$DIST/airbar"
(cd "$DIST" && rm -f "AirBar-$VERSION.zip" && ditto -c -k --norsrc --noextattr --keepParent AirBar.app "AirBar-$VERSION.zip" && zip -q "AirBar-$VERSION.zip" airbar)
echo "Built $APP and $DIST/AirBar-$VERSION.zip"
