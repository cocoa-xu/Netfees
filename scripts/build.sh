#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
configuration="${CONFIGURATION:-release}"
environment_code_sign_identity="${CODE_SIGN_IDENTITY:-${SIGNING_IDENTITY:-}}"
local_signing_config="${NETFEES_LOCAL_SIGNING_CONFIG:-.netfees-signing.local}"
if [[ "$local_signing_config" != /* ]]; then
    local_signing_config="$PWD/$local_signing_config"
fi
if [ -f "$local_signing_config" ]; then
    . "$local_signing_config"
fi
identity="${environment_code_sign_identity:-${CODE_SIGN_IDENTITY:--}}"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
swift build -c "$configuration" -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk_version"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app="build/NetFees.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/NetFees" "$app/Contents/MacOS/NetFees"
cp Resources/Info.plist "$app/Contents/Info.plist"
swift scripts/make-icon.swift
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
if [ "$identity" = "-" ]; then
    codesign --force --sign - "$app"
else
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
echo "Built and signed: $app"
