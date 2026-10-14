#!/usr/bin/env bash
# Renders the screenshots in docs/images from TwinTake's own views, with sample data.
#
# Usage: scripts/render-docs-images.sh [extra swift test options]
#
# It runs the DocShots test target (Tests/DocShots). That target is not part of TwinTake.app.
# It opens no camera, mic or screen capture, asks for no permission and shows no window: it
# draws the views offscreen. Run it on a Mac with a Retina display (the images are 2x).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/images"
cd "$ROOT"
mkdir -p "$OUT"

TWINTAKE_DOCSHOTS_DIR="$OUT" swift test --filter DocShots "$@"

for png in "$OUT"/*.png; do
  printf '%s  %sx%s\n' "${png#"$ROOT"/}" \
    "$(sips -g pixelWidth "$png" | awk '/pixelWidth/ {print $2}')" \
    "$(sips -g pixelHeight "$png" | awk '/pixelHeight/ {print $2}')"
done
