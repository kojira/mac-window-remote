#!/bin/sh
# Builds build/MacWindowRemote.app (DESIGN.md D17).
# Signing: set CODESIGN_IDENTITY to an Apple Development certificate so Screen Recording and
# Accessibility grants survive rebuilds. The default "-" is an ad-hoc signature.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/MacWindowRemote.app"

# `xcrun swift` picks the toolchain of the selected Xcode (or DEVELOPER_DIR), not whatever
# `swift` happens to be first in PATH.
cd "$ROOT/mac"
xcrun swift build -c release
BIN_DIR="$(xcrun swift build -c release --show-bin-path)"
# The license shipped inside the WebRTC xcframework (D20).
WEBRTC_LICENSE="$ROOT/mac/.build/artifacts/webrtc/WebRTC/WebRTC.xcframework/LICENSE"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/MacWindowRemote" "$APP/Contents/MacOS/MacWindowRemote"
cp "$ROOT/mac/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/web" "$APP/Contents/Resources/web"
# WebRTC.framework is loaded from @executable_path/../Frameworks (rpath in Package.swift).
cp -R "$BIN_DIR/WebRTC.framework" "$APP/Contents/Frameworks/WebRTC.framework"
cp "$WEBRTC_LICENSE" "$APP/Contents/Resources/WebRTC-LICENSE"

# Sign inside out: the embedded framework first, then the app.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP/Contents/Frameworks/WebRTC.framework"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
