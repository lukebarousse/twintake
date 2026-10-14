#!/usr/bin/env bash
# Builds a release TwinTake.app and installs it in /Applications.
#
# Usage: scripts/install.sh
#
# Permissions (camera, mic, screen, Accessibility) follow the code signature, not the path,
# so an install signed with the same certificate keeps them. The script refuses to replace a
# TwinTake that is recording, quits an idle one, and opens the new one when it is done.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.lukebarousse.twintake"
DEST="/Applications/TwinTake.app"

"$ROOT/scripts/build-app.sh" release
BUILT="$ROOT/build/TwinTake.app"

if pgrep -x TwinTake >/dev/null; then
  # A session folder whose session.json still says "recording" means a take is running.
  if grep -l '"status" : "recording"' "$HOME/Movies/TwinTake"/*/session.json >/dev/null 2>&1; then
    echo "TwinTake is recording. Stop the take, then run this again." >&2
    exit 1
  fi
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x TwinTake >/dev/null || break; sleep 0.5; done
  if pgrep -x TwinTake >/dev/null; then
    echo "TwinTake did not quit. Quit it from its menu, then run this again." >&2
    exit 1
  fi
fi

rm -rf "$DEST"
ditto "$BUILT" "$DEST"
# One copy only, so Spotlight and Launchpad show a single TwinTake.
rm -rf "$BUILT"
codesign --verify --strict "$DEST"
echo "Installed $DEST"
open "$DEST"
