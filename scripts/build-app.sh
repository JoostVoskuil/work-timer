#!/usr/bin/env bash
# Builds WorkTimer.app (menu-bar app with a Dock icon while its window is open) with SwiftPM and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/WorkTimerApp"
APP="build/WorkTimer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WorkTimer"
cp Sources/WorkTimerApp/Resources/WorkTimer.icns "$APP/Contents/Resources/WorkTimer.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>nl.foxhole.worktimer</string>
  <key>CFBundleName</key><string>WorkTimer</string>
  <key>CFBundleIconFile</key><string>WorkTimer</string>
  <key>CFBundleExecutable</key><string>WorkTimer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>WorkTimerBuildDate</key><string>${BUILD_DATE}</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP (ad-hoc signed). Copy it to /Applications and open it."
