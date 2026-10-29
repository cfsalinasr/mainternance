#!/usr/bin/env bash
# Verifies clean-architecture layer boundaries. Usage: check-boundaries.sh [ROOT]
#  - Domain may import only Foundation
#  - Presentation must not import MainternanceData
#  - Data must not import SwiftUI
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
status=0

report() {
    local label="$1" matches="$2"
    if [[ -n "$matches" ]]; then
        echo "Boundary violation: $label"
        echo "$matches"
        status=1
    fi
}

scan() {
    local dir="$ROOT/Sources/$1" pattern="$2"
    [[ -d "$dir" ]] || return 0
    grep -rnE --include='*.swift' "$pattern" "$dir" || true
}

report "MainternanceDomain may only import Foundation" \
    "$(scan MainternanceDomain '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+' | grep -vE 'import[[:space:]]+Foundation[[:space:]]*$' || true)"
report "MainternancePresentation must not import MainternanceData" \
    "$(scan MainternancePresentation '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+MainternanceData\b')"
report "MainternanceData must not import SwiftUI" \
    "$(scan MainternanceData '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+SwiftUI\b')"

exit "$status"
