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
BIN="$(xcrun swift build -c release --show-bin-path)/MacWindowRemote"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacWindowRemote"
cp "$ROOT/mac/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/web" "$APP/Contents/Resources/web"

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
