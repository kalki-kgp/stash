#!/bin/sh
# Builds and runs the tests against a scratch directory, then checks the test binary for leaks.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 -framework AppKit -lsqlite3 \
    Sources/Store.swift Sources/Capture.swift Sources/Paste.swift Tests/main.swift -o "$OUT/stash-tests"
export STASH_HOME="$OUT/home"
if [ "$1" = leaks ]; then
    MallocStackLogging=1 leaks --atExit -- "$OUT/stash-tests" | tail -25
else
    "$OUT/stash-tests"
fi
rm -rf "$OUT"
