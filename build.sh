#!/bin/bash
# Builds WisprLocal.app and installs it to ~/Applications.
#
#   ./build.sh                      build + install
#   ./build.sh --run                build + install + relaunch
#   ./build.sh --reset-permissions  forget the TCC grants so macOS re-prompts
#
# Why the reset exists: ad-hoc signatures (-s -) bind the Accessibility and
# Input Monitoring grants to the binary's code hash, so every rebuild silently
# invalidates them. See README for the permanent fix (self-signed certificate).

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="WisprLocal"
BUNDLE_ID="com.varunnayak.wisprlocal"
DEST="$HOME/Applications/$APP_NAME.app"

# Prefer a stable self-signed identity when one exists. This matters more than
# it looks: ad-hoc signatures (-s -) bind TCC grants to the binary's code hash,
# so every rebuild silently revokes Accessibility and Input Monitoring. A real
# signing identity keeps the designated requirement stable, and the grants stick.
# See README for how to create "WisprLocal Dev" if it's missing.
SIGNING_CERT="WisprLocal Dev"
if [[ -n "${WISPRLOCAL_IDENTITY:-}" ]]; then
    IDENTITY="$WISPRLOCAL_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGNING_CERT"; then
    IDENTITY="$SIGNING_CERT"
else
    IDENTITY="-"
fi

if [[ "${1:-}" == "--reset-permissions" ]]; then
    echo "Resetting TCC grants for $BUNDLE_ID..."
    tccutil reset Accessibility "$BUNDLE_ID"    || true
    tccutil reset ListenEvent   "$BUNDLE_ID"    || true
    tccutil reset Microphone    "$BUNDLE_ID"    || true
    tccutil reset SpeechRecognition "$BUNDLE_ID" || true
    echo "Done. Relaunch the app and grant them again."
    exit 0
fi

# /opt/homebrew on Apple silicon, /usr/local on Intel.
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export HOMEBREW_PREFIX="$BREW_PREFIX"

if [[ ! -f "$BREW_PREFIX/lib/libwhisper.dylib" ]]; then
    echo "warning: whisper-cpp not found. Run: brew install whisper-cpp" >&2
    if [[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]]; then
        echo "         (the Apple engine will still work without it)" >&2
    else
        echo "         (required — the Apple engine needs macOS 26 or later)" >&2
    fi
fi

# Build for whatever this Mac is, rather than assuming Apple silicon.
ARCH="$(uname -m)"
echo "==> Compiling for $ARCH (Homebrew at $BREW_PREFIX)"
swift build -c release --arch "$ARCH"

BIN=".build/release/$APP_NAME"
[[ -f "$BIN" ]] || { echo "build produced no binary" >&2; exit 1; }

echo "==> Assembling bundle"
STAGE=".build/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# No --options runtime: the hardened runtime enables library validation, which
# refuses to load Homebrew's differently-signed libwhisper. We aren't notarizing,
# so the hardened runtime buys nothing here anyway.
echo "==> Signing (identity: $IDENTITY)"
codesign --force \
         --entitlements Resources/WisprLocal.entitlements \
         --sign "$IDENTITY" "$STAGE" 2>&1 | sed 's/^/    /'

# Replacing a running app's bundle confuses LaunchServices; stop it first.
# Matched by full path so a long-running --selftest isn't caught in the net.
GUI_PATTERN="MacOS/$APP_NAME\$"
if pgrep -f "$GUI_PATTERN" > /dev/null; then
    echo "==> Quitting running instance"
    pkill -f "$GUI_PATTERN" || true
    sleep 1
fi

echo "==> Installing to $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$STAGE" "$DEST"

OLD_HASH_FILE="$HOME/Library/Application Support/$APP_NAME/.cdhash"
NEW_HASH=$(codesign -dvvv "$DEST" 2>&1 | awk -F= '/^CDHash/{print $2}')
if [[ -f "$OLD_HASH_FILE" ]] && [[ "$(cat "$OLD_HASH_FILE")" != "$NEW_HASH" ]] && [[ "$IDENTITY" == "-" ]]; then
    # Only a concern for ad-hoc builds; a real identity survives rebuilds.
    echo
    echo "  NOTE: the code hash changed, so macOS may have dropped the"
    echo "  Accessibility / Input Monitoring grants. If the hotkey stops"
    echo "  working, toggle WisprLocal off and on in System Settings ›"
    echo "  Privacy & Security, or run: ./build.sh --reset-permissions"
fi
mkdir -p "$(dirname "$OLD_HASH_FILE")"
echo "$NEW_HASH" > "$OLD_HASH_FILE"

echo
echo "Built $DEST"

if [[ "${1:-}" == "--run" ]]; then
    echo "==> Launching"
    open "$DEST"
fi
