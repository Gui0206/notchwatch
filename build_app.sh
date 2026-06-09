#!/bin/bash
# Builds NotchAIControl.app (a LSUIElement accessory app) and the notch-hook CLI.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
APP="NotchAIControl.app"
BUNDLE_ID="com.notchai.control"
VERSION="1.0.0"

echo "▸ Compiling (swift build -c $CONFIG)…"
swift build -c $CONFIG

BIN_DIR="$(swift build -c $CONFIG --show-bin-path)"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/NotchAIControl" "$APP/Contents/MacOS/NotchAIControl"
# Ship the hook helper inside the bundle so the installer can find it.
cp "$BIN_DIR/notch-hook" "$APP/Contents/Resources/notch-hook"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>NotchAIControl</string>
    <key>CFBundleDisplayName</key><string>Notch AI Control</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>NotchAIControl</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS is happy launching it locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built $APP"
echo "  Hook helper: $APP/Contents/Resources/notch-hook"
