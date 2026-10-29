#!/usr/bin/env bash
# Runs SwiftLint (strict) then SwiftFormat (lint mode); fails if either fails.
set -uo pipefail
cd "$(dirname "$0")/.."

CLT_PATH="/Library/Developer/CommandLineTools"
if [[ "$(xcode-select -p 2>/dev/null || true)" == "$CLT_PATH" ]]; then
    export DYLD_FRAMEWORK_PATH="$CLT_PATH/usr/lib"
fi

status=0
swiftlint --strict || status=1
swiftformat --lint . || status=1
exit "$status"
