#!/bin/bash
# Signs the debug build with the Developer ID and a fixed identifier, so the Keychain recognizes every rebuild
# as the same app: "Always Allow" once and later builds read the Inbox token without asking.
# (An ad-hoc signature's identity changes with each build, so the Keychain asks again every time.)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${1:-$ROOT/app/.build/debug/Octomux}
ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
[ -z "$ID" ] && { echo "sign-debug: no Developer ID identity; leaving the ad-hoc signature" >&2; exit 0; }
codesign -dv "$BIN" 2>&1 | grep -q "Identifier=dev.octomux.debug" && codesign -dv "$BIN" 2>&1 | grep -q "TeamIdentifier=[A-Z0-9]" \
  && codesign --verify "$BIN" 2>/dev/null && exit 0     # already signed and unchanged since
codesign --force --sign "$ID" --identifier dev.octomux.debug "$BIN" 2>&1 | grep -v "replacing existing signature"
exit 0
