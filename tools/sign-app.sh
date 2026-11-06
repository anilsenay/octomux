#!/bin/bash
# Signs an Octomux.app with a Developer ID, inside out, hardened runtime (what notarization requires).
# Usage: tools/sign-app.sh <path/to/Octomux.app> [--no-timestamp]   (identity: OCTOMUX_SIGN_ID or the first
# "Developer ID Application" in the keychain). Used by release.sh and install-local.sh.
set -euo pipefail
APP="$1"; TS="--timestamp"; [ "${2:-}" = --no-timestamp ] && TS="--timestamp=none"
SIGN_ID="${OCTOMUX_SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[ -n "$SIGN_ID" ] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
sign() { codesign --force $TS --options runtime --sign "$SIGN_ID" "$@"; }
sign "$APP/Contents/Resources/bin/octomux"
# The daemon's background app (see build-app.sh), signed as a bundle so its identifier is its own.
for h in "$APP"/Contents/Helpers/*.app; do [ -d "$h" ] && sign "$h"; done
# Sparkle's helpers, innermost first (as Sparkle documents for Developer ID apps).
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SP/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
codesign --verify --strict --deep "$APP"
echo "signed $APP with $SIGN_ID"
