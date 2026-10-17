#!/bin/sh
# Builds Stash.app and packs it into dist/Stash-<version>.dmg with a drag-to-Applications layout.
set -e
cd "$(dirname "$0")/.."
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
mkdir -p dist
DMG="dist/Stash-$VERSION.dmg"
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R Stash.app "$STAGE/"
create-dmg \
    --volname "Stash $VERSION" \
    --volicon Assets/AppIcon.icns \
    --window-size 540 360 \
    --icon-size 112 \
    --icon "Stash.app" 140 170 \
    --app-drop-link 400 170 \
    --hide-extension "Stash.app" \
    --no-internet-enable \
    "$DMG" "$STAGE" >/dev/null
rm -rf "$STAGE"
echo "$DMG"
