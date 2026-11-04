#!/bin/bash
# Publishes what tools/release.sh built: a GitHub release v<version> with the DMG, the update zip and the
# appcast (the app's feed URL points at releases/latest/download/appcast.xml). Notes from CHANGELOG.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(cat VERSION)"
. ./release.env
D=dist
for f in "$D/Octomux-$VERSION.dmg" "$D/Octomux-$VERSION.zip" "$D/updates/appcast.xml"; do
    [ -f "$f" ] || { echo "missing $f (run tools/release.sh first)" >&2; exit 1; }
done
grep -q "releases/download/v$VERSION/Octomux-$VERSION.zip" "$D/updates/appcast.xml" || { echo "appcast does not point at v$VERSION" >&2; exit 1; }
NOTES="$(mktemp)"; trap 'rm -f "$NOTES"' EXIT
awk -v v="$VERSION" '$0 ~ "^## "v"( |$)" {on=1; next} /^## / {on=0} on' CHANGELOG.md > "$NOTES"
cat >> "$NOTES" <<NOTES

### Install

Download **Octomux-$VERSION.dmg**, open it and drag Octomux into Applications. macOS 14+, Apple Silicon. Signed and
notarized. Already installed? Octomux offers the update itself.
NOTES
# The DMG under a stable name too, so "latest/download/Octomux.dmg" always works.
cp "$D/Octomux-$VERSION.dmg" "$D/Octomux.dmg"
gh release create "v$VERSION" -R "$OCTOMUX_GITHUB_REPO" --title "Octomux $VERSION" --notes-file "$NOTES" \
    "$D/Octomux.dmg" "$D/Octomux-$VERSION.dmg" "$D/Octomux-$VERSION.zip" "$D/updates/appcast.xml"
echo "published https://github.com/$OCTOMUX_GITHUB_REPO/releases/tag/v$VERSION"
