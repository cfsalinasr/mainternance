#!/usr/bin/env bash
# Runs swift test; adds the Swift Testing plugin flag on Command Line Tools-only setups.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT_PATH="/Library/Developer/CommandLineTools"
PLUGIN_DIR="$CLT_PATH/usr/lib/swift/host/plugins/testing"
FLAGS=()
if [[ -d "$PLUGIN_DIR" && "$(xcode-select -p 2>/dev/null || true)" == "$CLT_PATH" ]]; then
    FLAGS=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR")
fi
exec swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
