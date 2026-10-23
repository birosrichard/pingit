#!/bin/bash
# Build, sign, notarize, and package the app before generating its Homebrew cask.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${RELEASE_TEAM_ID:?Set RELEASE_TEAM_ID to the Apple signing team ID}"
: "${NOTARYTOOL_PROFILE:?Set NOTARYTOOL_PROFILE to a notarytool Keychain profile}"
[[ $RELEASE_TEAM_ID =~ ^[A-Z0-9]{10}$ ]] || { echo 'Invalid Apple team ID' >&2; exit 1; }

mkdir -p build/release
run_dir=$(mktemp -d "$PWD/build/release/run.XXXXXX")
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
echo "Release diagnostics and archive: $run_dir"

# Xcode's signed-in account supplies development and Developer ID profiles.
# Exporting replaces the archive's development signature/profile for distribution.
xcodebuild -project pingit.xcodeproj -scheme pingit -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$run_dir/pingit.xcarchive" \
    -derivedDataPath "$PWD/build/release/DerivedData" -allowProvisioningUpdates \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO DEVELOPMENT_TEAM="$RELEASE_TEAM_ID" archive

python3 - "$run_dir/ExportOptions.plist" "$RELEASE_TEAM_ID" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'method': 'developer-id', 'destination': 'export',
        'signingStyle': 'automatic', 'teamID': sys.argv[2],
    }, output)
PY
xcodebuild -exportArchive -archivePath "$run_dir/pingit.xcarchive" \
    -exportPath "$run_dir/export" -exportOptionsPlist "$run_dir/ExportOptions.plist" \
    -allowProvisioningUpdates

app="$run_dir/export/pingit.app"
bash scripts/validate-app.sh "$app"
lipo "$app/Contents/MacOS/pingit" -verify_arch arm64
lipo "$app/Contents/MacOS/pingit" -verify_arch x86_64
codesign -d --entitlements :- "$app" > "$run_dir/entitlements.plist" 2>/dev/null
codesign -dvvv "$app" 2> "$run_dir/signature.txt"
security cms -D -i "$app/Contents/embedded.provisionprofile" > "$run_dir/profile.plist"
python3 - "$run_dir" "$RELEASE_TEAM_ID" <<'PY'
import datetime, pathlib, plistlib, sys
root, team = pathlib.Path(sys.argv[1]), sys.argv[2]
def check(condition, message):
    if not condition:
        raise SystemExit(message)
entitlements = plistlib.loads((root / 'entitlements.plist').read_bytes())
profile = plistlib.loads((root / 'profile.plist').read_bytes())
signature = (root / 'signature.txt').read_text()
check('Authority=Developer ID Application:' in signature, 'Developer ID signature required')
check(f'TeamIdentifier={team}\n' in signature, 'Wrong signing team')
check('(runtime)' in signature, 'Hardened Runtime required')
check(profile.get('ProvisionsAllDevices') is True, 'Developer ID profile required')
check(profile['TeamIdentifier'] == [team], 'Wrong provisioning team')
check(profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Expired profile')
check(entitlements.get('keychain-access-groups') == [f'{team}.dev.biros.pingit'], 'Missing app Keychain group')
check(not entitlements.get('com.apple.security.get-task-allow'), 'Debug entitlement in release')
PY

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected major.minor.patch version' >&2; exit 1; }
artifact="$PWD/build/release/pingit-$version.zip"
[[ ! -e $artifact ]] || { echo "Refusing to replace $artifact; bump the app version for a new release." >&2; exit 1; }

ditto -c -k --keepParent "$app" "$run_dir/submission.zip"
xcrun notarytool submit "$run_dir/submission.zip" --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait --output-format json > "$run_dir/notarization.json"
python3 - "$run_dir/notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit(f'Notarization failed: {result}. See notarytool log for details.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"

# Stapling changes the app: checksum only the ZIP made after that step.
ditto -c -k --keepParent "$app" "$run_dir/pingit-$version.zip"
python3 scripts/generate-cask.py "$run_dir/pingit-$version.zip" > "$run_dir/pingit.rb"
cp "$run_dir/pingit-$version.zip" "$artifact"
cp "$run_dir/pingit.rb" build/release/pingit.rb
shasum -a 256 "$artifact"
echo "Ready to publish: $artifact"
echo "Homebrew cask: $PWD/build/release/pingit.rb"
