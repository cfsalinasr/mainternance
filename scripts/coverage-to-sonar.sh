#!/usr/bin/env bash
# Converts the SwiftPM coverage data produced by `scripts/test.sh --enable-code-coverage` into SonarCloud's
# generic coverage XML (coverage.xml at the repo root), with only Sources/ files and repo-relative paths.
# Works with Command Line Tools only and with Xcode (both provide `xcrun llvm-cov`).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

BUILD_DIR="${MAINTERNANCE_BUILD_DIR:-$HOME/Library/Caches/mainternance}/build"
OUT="${1:-$ROOT/coverage.xml}"

# SwiftPM reports where the merged profile lives; the same folder sits next to the built test bundles.
CODECOV_JSON="$(swift test --scratch-path "$BUILD_DIR" --show-codecov-path 2>/dev/null | tail -1)"
PROFDATA="$(dirname "$CODECOV_JSON")/default.profdata"
if [[ ! -f "$PROFDATA" ]]; then
    echo "ERROR: no coverage profile at $PROFDATA; run scripts/test.sh --enable-code-coverage first." >&2
    exit 1
fi

# Every test bundle's binary; the profile merges all of them. `-L` follows the build dir's `debug` symlink.
OBJECTS=()
while IFS= read -r binary; do
    OBJECTS+=("$binary")
done < <(find -L "$BUILD_DIR/debug" -maxdepth 4 -path '*.xctest/Contents/MacOS/*' -type f | sort)
if [[ ${#OBJECTS[@]} -eq 0 ]]; then
    echo "ERROR: no .xctest binaries under $BUILD_DIR/debug; run scripts/test.sh --enable-code-coverage first." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ARGS=("-instr-profile=$PROFDATA" "-format=lcov" "${OBJECTS[0]}")
for object in "${OBJECTS[@]:1}"; do
    ARGS+=("-object=$object")
done
xcrun llvm-cov export "${ARGS[@]}" > "$WORK/coverage.lcov"

python3 -I - "$WORK/coverage.lcov" "$OUT" "$ROOT" <<'PY'
import sys
from xml.sax.saxutils import quoteattr

lcov_path, out_path, root = sys.argv[1], sys.argv[2], sys.argv[3].rstrip("/") + "/"
files = {}  # relative path -> {line: covered}
current = None
with open(lcov_path, encoding="utf-8") as lcov:
    for raw in lcov:
        line = raw.strip()
        if line.startswith("SF:"):
            path = line[3:]
            current = None
            if path.startswith(root) and path[len(root):].startswith("Sources/"):
                current = files.setdefault(path[len(root):], {})
        elif line.startswith("DA:") and current is not None:
            number, count = line[3:].split(",")[:2]
            current[int(number)] = current.get(int(number), False) or int(count) > 0

total = covered = 0
with open(out_path, "w", encoding="utf-8") as out:
    out.write('<coverage version="1">\n')
    for path in sorted(files):
        out.write(f"  <file path={quoteattr(path)}>\n")
        for number in sorted(files[path]):
            hit = files[path][number]
            total += 1
            covered += hit
            out.write(f'    <lineToCover lineNumber="{number}" covered="{str(hit).lower()}"/>\n')
        out.write("  </file>\n")
    out.write("</coverage>\n")
percent = 100 * covered / total if total else 0
print(f"Wrote {out_path}: {len(files)} files, {covered}/{total} lines covered ({percent:.1f}%)")
PY
