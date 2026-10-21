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
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$entitlements")" = true ] \
    || fail "Outbound networking must be enabled"
group=$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$entitlements")
case "$group" in
    "$expected_bundle_id"|*."$expected_bundle_id") ;;
    *) fail "Missing app-specific Keychain access group" ;;
esac
if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:1' "$entitlements" >/dev/null 2>&1; then
    fail "Unexpected shared Keychain access group"
fi
# Phase 2 needs outbound HTTPS and its own Keychain group, without file/server exceptions.
if /usr/libexec/PlistBuddy -c Print "$entitlements" | /usr/bin/grep -Eq 'com\.apple\.security\.(network\.server|files\.|temporary-exception\.)'; then
    fail "Unexpected server, file, or temporary-exception entitlement in Phase 2"
fi
if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity' "$info" >/dev/null 2>&1; then
    fail "Unexpected App Transport Security override"
fi

echo "PASS: bundle, agent configuration, version, signature, sandbox, networking, Keychain group, and ATS"
