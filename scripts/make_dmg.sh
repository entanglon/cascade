#!/bin/bash
# make_dmg.sh — builds the Cascade installer DMG from the Release app.
# Usage: ./scripts/make_dmg.sh [version]
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-1.2.0}"
DMG_OUT="Cascade-${VERSION}.dmg"

# Locate Release app: check local build/ first, then Xcode DerivedData
APP_SRC=""
if [ -d "build/Build/Products/Release/Cascade.app" ]; then
    APP_SRC="build/Build/Products/Release/Cascade.app"
else
    # Find latest built Release Cascade.app in DerivedData
    FOUND=$(find ~/Library/Developer/Xcode/DerivedData/Cascade-*/Build/Products/Release/Cascade.app -maxdepth 0 2>/dev/null | head -n 1 || true)
    if [ -n "$FOUND" ] && [ -d "$FOUND" ]; then
        APP_SRC="$FOUND"
    fi
fi

if [ -z "$APP_SRC" ] || [ ! -d "$APP_SRC" ]; then
    echo "Release app not found. Building it now with xcodebuild..."
    xcodebuild -project Cascade.xcodeproj -scheme Cascade -configuration Release -destination 'platform=macOS' build
    APP_SRC=$(find ~/Library/Developer/Xcode/DerivedData/Cascade-*/Build/Products/Release/Cascade.app -maxdepth 0 2>/dev/null | head -n 1)
fi

echo "==> Using Release app: $APP_SRC"

STAGE="build/dmg-staging"
rm -rf "$STAGE" "$DMG_OUT"
mkdir -p "$STAGE"

echo "==> Staging Cascade.app"
cp -R "$APP_SRC" "$STAGE/Cascade.app"
rm -rf "$STAGE/Cascade.app.dSYM" 2>/dev/null || true

echo "==> Rendering DMG background"
ICON_ASSET="Public/files/Cascade-v2-icon-1024.png"
if [ ! -f "$ICON_ASSET" ]; then
    ICON_ASSET="icon.png"
fi
swift scripts/make_dmg_background.swift "$ICON_ASSET" "build/dmg-background.png"

echo "==> Preparing volume icon"
VOLUME_ICNS="build/Cascade.icns"
if [ -f "Public/files/Cascade-v2.icns" ]; then
    cp "Public/files/Cascade-v2.icns" "$VOLUME_ICNS"
else
    mkdir -p build/AppIcon.iconset
    for s in 16 32 128 256 512; do
        if [ -f "Cascade/Assets.xcassets/AppIcon.appiconset/icon-${s}x${s}.png" ]; then
            cp "Cascade/Assets.xcassets/AppIcon.appiconset/icon-${s}x${s}.png" "build/AppIcon.iconset/icon_${s}x${s}.png"
            cp "Cascade/Assets.xcassets/AppIcon.appiconset/icon-${s}x${s}@2x.png" "build/AppIcon.iconset/icon_${s}x${s}@2x.png"
        fi
    done
    iconutil -c icns build/AppIcon.iconset -o "$VOLUME_ICNS"
fi

echo "==> Creating DMG"
if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "Cascade" \
        --volicon "$VOLUME_ICNS" \
        --background "build/dmg-background.png" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 112 \
        --icon "Cascade.app" 170 180 \
        --hide-extension "Cascade.app" \
        --app-drop-link 490 180 \
        --overwrite \
        "$DMG_OUT" \
        "$STAGE"
else
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Cascade" -srcfolder "$STAGE" -ov -format UDZO "$DMG_OUT"
fi

if [ -f "$DMG_OUT" ]; then
    echo "==> Verifying DMG"
    hdiutil verify "$DMG_OUT"
    echo
    echo "✅ Successfully built: $DMG_OUT ($(du -h "$DMG_OUT" | cut -f1))"
else
    echo "❌ Failed to create $DMG_OUT"
    exit 1
fi
