#!/usr/bin/env bash
# Runs swift test; adds the Swift Testing plugin flag on Command Line Tools-only setups.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT_PATH="/Library/Developer/CommandLineTools"
PLUGIN_DIR="$CLT_PATH/usr/lib/swift/host/plugins/testing"
# Build out-of-tree: an iCloud-synced Desktop corrupts in-repo build products (codesign fails).
BUILD_DIR="${MAINTERNANCE_BUILD_DIR:-$HOME/Library/Caches/mainternance/build}"
mkdir -p "$BUILD_DIR"
FLAGS=()
if [[ -d "$PLUGIN_DIR" && "$(xcode-select -p 2>/dev/null || true)" == "$CLT_PATH" ]]; then
    FLAGS=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR")
fi
exec swift test --scratch-path "$BUILD_DIR" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
