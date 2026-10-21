#!/bin/sh
# Validate the built product rather than relying on source build settings.
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 path/to/pingit.app [expected-bundle-id]" >&2
    exit 1
fi

app=$1
expected_bundle_id=${2:-dev.biros.pingit}
info="$app/Contents/Info.plist"
entitlements=$(mktemp)
trap 'rm -f "$entitlements"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$info"; }

plutil -lint "$info"
[ "$(value CFBundleIdentifier)" = "$expected_bundle_id" ] || fail "Unexpected bundle ID"
[ "$(value CFBundlePackageType)" = APPL ] || fail "Expected an application bundle"
[ "$(value LSUIElement)" = true ] || fail "App must run without a persistent Dock icon"
[ "$(value LSMinimumSystemVersion)" = 14.0 ] || fail "Expected macOS 14.0 deployment target"
[ -n "$(value CFBundleShortVersionString)" ] || fail "Missing app version"
[ -n "$(value CFBundleVersion)" ] || fail "Missing build number"
[ -x "$app/Contents/MacOS/$(value CFBundleExecutable)" ] || fail "Missing executable"

codesign --verify --strict "$app"
codesign -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements")" = true ] \
    || fail "App Sandbox must be enabled"
# No network or file access should be granted by the Phase 1 product.
if /usr/libexec/PlistBuddy -c Print "$entitlements" | /usr/bin/grep -Eq 'com\.apple\.security\.(network\.|files\.)'; then
    fail "Unexpected network or file entitlement in Phase 1"
fi

echo "PASS: bundle, agent lifecycle configuration, version, executable, signature, and sandbox"
