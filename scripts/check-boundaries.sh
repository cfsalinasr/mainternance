#!/usr/bin/env bash
# Verifies clean-architecture layer boundaries. Usage: check-boundaries.sh [ROOT]
#  - Domain may import only Foundation
#  - Presentation must not import MainternanceData
#  - Data must not import SwiftUI
# Comments are stripped and statements split on ';' before each import is judged.
# Exit: 0 clean, 1 violations, 2 usage/IO error.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

if [[ ! -d "$ROOT" ]]; then
    echo "error: ROOT '$ROOT' is not a directory" >&2
    exit 2
fi
if [[ ! -d "$ROOT/Sources" ]]; then
    echo "error: '$ROOT/Sources' does not exist" >&2
    exit 2
fi

# awk -v mode=domain|presentation|data FILE ; exit 1 on violation, prints offenders.
AWK_PROGRAM='
function judge(stmt,    rest, mod, n, parts) {
    sub(/^[ \t]+/, "", stmt); sub(/[ \t]+$/, "", stmt)
    if (stmt !~ /^(@[A-Za-z_]+(\([^)]*\))?[ \t]+)*import[ \t]+/) return
    rest = stmt
    sub(/^(@[A-Za-z_]+(\([^)]*\))?[ \t]+)*import[ \t]+/, "", rest)
    if (rest ~ /^(typealias|struct|class|enum|protocol|let|var|func)[ \t]+/)
        sub(/^[A-Za-z]+[ \t]+/, "", rest)
    mod = rest
    sub(/[ \t].*$/, "", mod)
    sub(/\..*$/, "", mod)
    bad = 0
    if (mode == "domain" && (mod != "Foundation" || rest ~ /^Foundation\./)) bad = 1
    if (mode == "domain" && stmt ~ /import[ \t]+(typealias|struct|class|enum|protocol|let|var|func)[ \t]/) bad = 1
    if (mode == "presentation" && mod == "MainternanceData") bad = 1
    if (mode == "data" && mod == "SwiftUI") bad = 1
    if (bad) { printf "%s:%d: %s\n", FILENAME, FNR, stmt; violations = 1 }
}
FNR == 1 { inblock = 0 }
{
    line = $0; out = ""; n = length(line); i = 1; instr = 0
    while (i <= n) {
        c = substr(line, i, 1); d = substr(line, i, 2)
        if (inblock) {
            if (d == "*/") { inblock = 0; i += 2; out = out " " } else i++
        } else if (instr) {
            if (c == "\\") { out = out substr(line, i, 2); i += 2 }
            else { if (c == "\"") instr = 0; out = out c; i++ }
        } else if (d == "/*") { inblock = 1; i += 2 }
        else if (d == "//") break
        else { if (c == "\"") instr = 1; out = out c; i++ }
    }
    m = split(out, parts, ";")
    for (k = 1; k <= m; k++) judge(parts[k])
}
END { exit violations ? 1 : 0 }
'

status=0
for layer in "MainternanceDomain:domain" "MainternancePresentation:presentation" "MainternanceData:data"; do
    dir="$ROOT/Sources/${layer%%:*}"
    mode="${layer##*:}"
    [[ -d "$dir" ]] || continue
    files="$(find "$dir" -type f -name '*.swift')" || { echo "error: cannot scan $dir" >&2; exit 2; }
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        awk -v mode="$mode" "$AWK_PROGRAM" "$file"
        rc=$?
        if (( rc == 1 )); then
            echo "Boundary violation in layer ${layer%%:*} (see above)"
            status=1
        elif (( rc != 0 )); then
            echo "error: could not read $file" >&2
            exit 2
        fi
    done <<< "$files"
done
exit "$status"
