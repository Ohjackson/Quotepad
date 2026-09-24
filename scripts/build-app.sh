#!/bin/bash
# Builds QuickMemo.app into ./build. With --install, replaces ~/Applications/QuickMemo.app and launches it.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/QuickMemo.app"
VERSION="1.0"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/QuickMemo "$APP/Contents/MacOS/QuickMemo"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.micheal.QuickMemo</string>
    <key>CFBundleName</key>
    <string>QuickMemo</string>
    <key>CFBundleDisplayName</key>
    <string>QuickMemo</string>
    <key>CFBundleExecutable</key>
    <string>QuickMemo</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/QuickMemo.app"
    # Graceful quit (SIGTERM) so the running copy flushes its notes first.
    pkill -TERM -x QuickMemo 2>/dev/null || true
    for _ in {1..20}; do pgrep -x QuickMemo >/dev/null || break; sleep 0.1; done
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi
