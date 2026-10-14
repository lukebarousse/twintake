#!/usr/bin/env bash
# Builds build/TwinTake.app from the Swift package.
#
# Usage: scripts/build-app.sh [debug|release]
#
# Signing: macOS ties camera, mic, screen and Accessibility permissions to the code signature.
# The script signs with SIGN_IDENTITY if set, else the first "Apple Development" identity in
# your keychain (Xcode > Settings > Accounts creates one for free). With neither, it signs
# ad hoc, and macOS asks for the permissions again after every build.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TwinTake"
APP="$ROOT/build/$APP_NAME.app"
cd "$ROOT"

swift build -c "$CONFIG" --product "$APP_NAME"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
# The MIT licenses of this app and of the code it adapts travel with every copy.
cp "$ROOT/LICENSE" "$ROOT/NOTICE.md" "$APP/Contents/Resources/"

GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
/usr/libexec/PlistBuddy -c "Set :RecorderGitSha $GIT_SHA" "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "warning: no signing identity found; signing ad hoc (permissions reset on each build)" >&2
  IDENTITY="-"
fi

codesign --force --options runtime --timestamp=none \
  --entitlements "$ROOT/App/$APP_NAME.entitlements" \
  --sign "$IDENTITY" "$APP"

echo "$APP"
