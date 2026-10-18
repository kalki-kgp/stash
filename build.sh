#!/bin/sh
# Builds Stash.app with the Command Line Tools alone (no Xcode needed), as one universal binary
# for Apple silicon and Intel. ARCHS="arm64" builds a single slice for quicker local builds.
set -e
cd "$(dirname "$0")"
APP="Stash.app"
ARCHS="${ARCHS:-arm64 x86_64}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
FLAGS=""; [ "$1" = test ] && FLAGS="-D STASH_TEST"
OUT=$(mktemp -d)
# Each slice compiles in parallel; a failure in either stops the build.
PIDS=""
for ARCH in $ARCHS; do
    swiftc -O $FLAGS -swift-version 5 -parse-as-library -target "$ARCH-apple-macosx26.0" \
        -framework SwiftUI -framework AppKit -framework Carbon -lsqlite3 \
        -module-cache-path "$OUT/cache-$ARCH" \
        Sources/*.swift -o "$OUT/Stash-$ARCH" &
    PIDS="$PIDS $!"
done
for PID in $PIDS; do wait "$PID"; done
lipo -create "$OUT"/Stash-* -output "$APP/Contents/MacOS/Stash"
rm -rf "$OUT"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Assets/AppIcon.icns ] && cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/"
codesign --force --sign - --identifier dev.kalki.stash "$APP"
echo "built $PWD/$APP ($(lipo -archs "$APP/Contents/MacOS/Stash"))"
