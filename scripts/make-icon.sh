#!/usr/bin/env bash
# Generates AppIcon.icns (no Xcode): Swift renders a 1024px PNG, sips resizes, iconutil packs.
# Output goes to the build dir, never into the repo.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_ROOT="${MAINTERNANCE_BUILD_DIR:-$HOME/Library/Caches/mainternance}"
ICON_DIR="$OUT_ROOT/icon"
ICONSET="$ICON_DIR/AppIcon.iconset"
MASTER="$ICON_DIR/icon-1024.png"
ICNS="$ICON_DIR/AppIcon.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

swift scripts/make-icon.swift "$MASTER"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "Icon written to $ICNS"
