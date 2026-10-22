#!/bin/bash
# Build the app and run all shared-scheme tests without developer credentials.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build/ci
run_dir=$(mktemp -d "$PWD/build/ci/run.XXXXXX")

main() {
    if [[ $(uname -s) != Darwin ]]; then
        echo 'error: macOS and a full Xcode installation are required.' >&2
        return 1
    fi

    export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
    echo "Diagnostics: $run_dir"
    echo "Selected developer directory: $DEVELOPER_DIR"
    echo 'Installed Xcode applications:'
    find /Applications -maxdepth 1 -name 'Xcode*.app' -print
    if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
        echo "error: Full Xcode is unavailable at $DEVELOPER_DIR; set DEVELOPER_DIR to your Xcode app's Contents/Developer directory." >&2
        return 1
    fi

    local xcode_version
    xcode_version=$(xcodebuild -version)
    echo "$xcode_version"
    if [[ "${GITHUB_ACTIONS:-false}" == true && "$xcode_version" != $'Xcode 26.3\nBuild version 17C529' ]]; then
        echo 'error: Expected Xcode 26.3 (17C529); refusing to use a different toolchain.' >&2
        return 1
    fi
    sw_vers
    uname -m
    xcrun --find swift
    xcrun swift --version
    xcodebuild -showsdks

    # The shared scheme includes pingit.app with buildForTesting=YES and every
    # test in pingitTests. A separate build action would repeat this work.
    # Manual ad hoc signing overrides the committed team/profile requirements.
    # Preview entitlements retain sandbox/networking and omit restricted Keychain groups.
    xcodebuild \
        -project pingit.xcodeproj \
        -scheme pingit \
        -configuration Debug \
        -destination "platform=macOS,arch=$(uname -m)" \
        -derivedDataPath "$PWD/build/ci/DerivedData" \
        -resultBundlePath "$run_dir/TestResults.xcresult" \
        SWIFT_VERSION=6.0 \
        SWIFT_STRICT_CONCURRENCY=complete \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
        GCC_TREAT_WARNINGS_AS_ERRORS=YES \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGN_ENTITLEMENTS=pingit/Resources/pingit-preview.entitlements \
        DEVELOPMENT_TEAM= \
        PROVISIONING_PROFILE= \
        PROVISIONING_PROFILE_SPECIFIER= \
        test
}

# Keep raw compiler/test output in the Actions console and an artifact. pipefail
# preserves xcodebuild's failure status through tee (including failing tests).
main 2>&1 | tee "$run_dir/ci.log"
