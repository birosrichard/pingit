#!/bin/sh
# Catch launch-time policy rejection that a static codesign verification can miss.
set -eu

[ "$#" -eq 1 ] || { echo "Usage: $0 path/to/pingit.app" >&2; exit 1; }
app=$(cd "$1" && pwd)
name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
executable="$app/Contents/MacOS/$name"
pid=
cleanup() {
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM

"$executable" >/dev/null 2>&1 &
pid=$!
sleep 2
if ! kill -0 "$pid" 2>/dev/null; then
    status=0
    wait "$pid" || status=$?
    pid=
    echo "FAIL: app exited during startup (status $status)" >&2
    exit 1
fi

echo "PASS: app survived startup; stopping the smoke-test instance"
