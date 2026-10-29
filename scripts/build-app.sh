#!/usr/bin/env bash
# Builds the release executable, assembles Mainternance.app, signs it and verifies the signature.
# Everything is built out of the repo (an iCloud-synced Desktop breaks codesign).
# Usage: scripts/build-app.sh [--install]   (--install also copies the app to /Applications)
set -euo pipefail
# MAINTERNANCE_BUILD_DIR is the cache ROOT (default ~/Library/Caches/mainternance); build, dist and icon live under it.
cd "$(dirname "$0")/.."

INSTALL=0
case "${1:-}" in
    "") ;;
    --install) INSTALL=1 ;;
    *) echo "usage: $0 [--install]" >&2; exit 2 ;;
esac

APP_NAME="Mainternance"
IDENTITY="Mainternance Local Signing"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
OUT_ROOT="${MAINTERNANCE_BUILD_DIR:-$HOME/Library/Caches/mainternance}"
SCRATCH="$OUT_ROOT/build"
APP="$OUT_ROOT/dist/$APP_NAME.app"
ICNS="$OUT_ROOT/icon/AppIcon.icns"

echo "Building $APP_NAME $VERSION ($BUILD_NUMBER) in release mode..."
swift build -c release --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"

[[ -f "$ICNS" ]] || scripts/make-icon.sh

echo "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    Resources/Info.plist.template > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

# Extended attributes (Finder info, iCloud metadata) make codesign fail.
xattr -cr "$APP"

# The hardened runtime (--options runtime) is enabled: this app has no JIT, no unsigned plugins and
# no third-party libraries, so it launches fine with a local or ad-hoc signature.
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "Signing with identity '$IDENTITY'"
    codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
else
    echo "WARNING: signing identity '$IDENTITY' not found; signing ad-hoc." >&2
    echo "WARNING: with ad-hoc signing macOS may reset Full Disk Access after every rebuild." >&2
    echo "WARNING: run scripts/make-signing-cert.sh once to create a stable identity." >&2
    codesign --force --deep --options runtime --sign - "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built and signed: $APP"

if [[ "$INSTALL" -eq 1 ]]; then
    DEST="/Applications/$APP_NAME.app"
    STAGE="/Applications/.$APP_NAME.app.new"
    OLD="/Applications/.$APP_NAME.app.old"
    if pgrep -x "$APP_NAME" >/dev/null; then
        osascript -e 'tell application id "com.cfsalinasr.mainternance" to quit' || true
        for _ in $(seq 1 20); do
            pgrep -x "$APP_NAME" >/dev/null || break
            sleep 0.5
        done
        if pgrep -x "$APP_NAME" >/dev/null; then
            echo "ERROR: $APP_NAME is still running; quit it and re-run. /Applications was not touched." >&2
            exit 1
        fi
    fi
    # A previous run that failed mid-swap may have left the only copy aside; restore it, never delete it.
    if [[ -e "$OLD" && ! -e "$DEST" ]]; then
        mv "$OLD" "$DEST"
    fi
    rm -rf "$STAGE" "$OLD"
    ditto "$APP" "$STAGE" || { rm -rf "$STAGE"; echo "ERROR: copy failed; existing install untouched." >&2; exit 1; }
    [[ -e "$DEST" ]] && mv "$DEST" "$OLD"
    mv "$STAGE" "$DEST" || {
        # Never leave the user without an app: put the previous bundle back before giving up.
        rm -rf "$STAGE"
        if [[ -e "$OLD" ]]; then
            if [[ ! -e "$DEST" ]] && mv "$OLD" "$DEST"; then
                echo "ERROR: installing the new bundle failed; the previous install was restored at $DEST." >&2
            else
                echo "ERROR: installing the new bundle failed; the previous install is at $OLD (move it back to $DEST)." >&2
            fi
        else
            echo "ERROR: installing the new bundle failed; nothing was installed at $DEST." >&2
        fi
        exit 1
    }
    rm -rf "$OLD"
    echo "Installed: $DEST"
fi
