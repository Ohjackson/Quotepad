#!/bin/bash
# Builds Quotepad.app and packages it as build.noindex/Quotepad-<version>.dmg:
# a disk image with the app next to an Applications shortcut for drag-and-drop install.
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build.noindex/Quotepad.app/Contents/Info.plist)
STAGING="build.noindex/dmg"
DMG="build.noindex/Quotepad-${VERSION}.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R build.noindex/Quotepad.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Quotepad" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
echo "Built $DMG"
