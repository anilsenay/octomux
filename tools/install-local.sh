#!/bin/bash
# Maintainer's "install what I just built": builds a release, signs it with the Developer ID (no notarization,
# it never leaves this Mac), replaces /Applications/Octomux.app and reopens it. The daemon restarts into the new
# binary (sessions survive), workspaces and settings stay. The build keeps the update feed, and its build number
# is the commit count, so the next published release still arrives as an update.
# Needs the Developer ID certificate; without one, use the Dev variant instead (docs/DEVELOPMENT.md).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
set -a; . ./release.env; set +a
DEST="${OCTOMUX_INSTALL_DIR:-/Applications}/Octomux.app"

tools/build-app.sh release
tools/sign-app.sh build/Octomux.app --no-timestamp

# Quit the running copy (sessions keep running in the daemon) and wait for it to go.
if pgrep -xq Octomux; then
    osascript -e 'tell application id "dev.octomux.app" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -xq Octomux || break; sleep 0.1; done
fi
pgrep -xq Octomux && { echo "Octomux is still running; quit it and run again" >&2; exit 1; }

STAGE="$(dirname "$DEST")/.Octomux-installing.app"
rm -rf "$STAGE"
ditto build/Octomux.app "$STAGE"
rm -rf "$DEST"
mv "$STAGE" "$DEST"
open "$DEST"
echo "installed $DEST ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Contents/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$DEST/Contents/Info.plist"))"
