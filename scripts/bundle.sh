#!/bin/bash
# Builds StatusApps.app from the SwiftPM executable.
#
# The app has to be a real bundle for two reasons: LSUIElement keeps it out of the Dock, and
# SMAppService (the "open at login" toggle) refuses to work on a loose binary.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="StatusApps"
BUNDLE="${APP_NAME}.app"
VERSION="${VERSION:-1.0.0}"

echo "==> Building release binary"
swift build -c release --product "$APP_NAME"
BINARY="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"

echo "==> Assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Status Apps</string>
    <key>CFBundleDisplayName</key><string>Status Apps</string>
    <key>CFBundleIdentifier</key><string>com.agudeluca.statusapps</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for a locally built app, and required for SMAppService to register it.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE"

echo "==> Done: $(pwd)/$BUNDLE"
