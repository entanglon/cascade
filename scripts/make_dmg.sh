#!/bin/bash
# make_dmg.sh — builds the xCloud installer DMG from the Release app.
# Usage: ./scripts/make_dmg.sh [version]
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
APP_SRC="build/Build/Products/Release/xCloud.app"
DMG_OUT="xCloud-${VERSION}.dmg"

if [ ! -d "$APP_SRC" ]; then
    echo "Release app not found at $APP_SRC — build it first:"
    echo "  xcodebuild -project xCloud.xcodeproj -scheme xCloud -configuration Release -derivedDataPath build build"
    exit 1
fi

STAGE="build/dmg-staging"
TOOLS="build/dmgbuild-tools"
rm -rf "$STAGE" "$DMG_OUT"
mkdir -p "$STAGE"

echo "==> Staging app"
cp -R "$APP_SRC" "$STAGE/xCloud.app"
# Don't ship the debug dSYMs or any build cruft
rm -rf "$STAGE/xCloud.app.dSYM" 2>/dev/null || true

echo "==> Rendering background"
swift scripts/make_dmg_background.swift icon.png "build/dmg-background.png"

echo "==> Building volume icon (.icns)"
rm -rf build/AppIcon.iconset build/xCloud.icns
mkdir -p build/AppIcon.iconset
for s in 16 32 128 256 512; do
    cp "xCloud/Assets.xcassets/AppIcon.appiconset/icon_${s}x${s}.png" "build/AppIcon.iconset/icon_${s}x${s}.png"
    cp "xCloud/Assets.xcassets/AppIcon.appiconset/icon_${s}x${s}@2x.png" "build/AppIcon.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns build/AppIcon.iconset -o build/xCloud.icns

echo "==> Creating DMG"
PYTHONPATH="$TOOLS" python3 scripts/build_dmg.py "$DMG_OUT" "$STAGE" "build/dmg-background.png" "build/xCloud.icns"

echo "==> Verifying"
hdiutil verify "$DMG_OUT"
echo
echo "Done: $DMG_OUT ($(du -h "$DMG_OUT" | cut -f1))"
