#!/bin/sh
# Builds Stash.app with the Command Line Tools alone (no Xcode needed).
set -e
cd "$(dirname "$0")"
APP="Stash.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
FLAGS=""; [ "$1" = test ] && FLAGS="-D STASH_TEST"
swiftc -O $FLAGS -swift-version 5 -parse-as-library -target arm64-apple-macosx26.0 \
    -framework SwiftUI -framework AppKit -framework Carbon -lsqlite3 \
    Sources/*.swift -o "$APP/Contents/MacOS/Stash"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Assets/AppIcon.icns ] && cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier dev.kalki.stash "$APP"
echo "built $PWD/$APP"
