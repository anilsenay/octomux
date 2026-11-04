#!/bin/bash
# Builds a distributable Octomux: Developer ID signed (hardened runtime), notarized and stapled.
# Output in dist/: Octomux-<version>.dmg (for people to download) and Octomux-<version>.zip (for the updater),
# plus dist/updates/ (appcast.xml and the update zips, EdDSA-signed) to upload where OCTOMUX_FEED_URL points.
# Usage: tools/release.sh            (version from VERSION, build number = commit count)
# Needs: the "Developer ID Application" certificate in the login keychain and the notarytool profile
#   xcrun notarytool store-credentials octomux-notary --apple-id <apple id> --team-id <team id>
# Env: OCTOMUX_SIGN_ID (default: the first Developer ID Application identity), OCTOMUX_NOTARY_PROFILE
#   (default octomux-notary), OCTOMUX_SKIP_NOTARIZE=1 (sign only, for a quick local check).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(cat VERSION)"
[ -f release.env ] && set -a && . ./release.env && set +a
SPARKLE_BIN="$ROOT/app/.build/artifacts/sparkle/Sparkle/bin"
[ -n "${OCTOMUX_GITHUB_REPO:-}" ] && : "${OCTOMUX_DOWNLOAD_PREFIX:=https://github.com/$OCTOMUX_GITHUB_REPO/releases/download/v$VERSION/}"
PROFILE="${OCTOMUX_NOTARY_PROFILE:-octomux-notary}"
SIGN_ID="${OCTOMUX_SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[ -n "$SIGN_ID" ] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
if [ -n "$(git status --porcelain)" ]; then echo "warning: uncommitted changes go into this build" >&2; fi

echo "== build $VERSION ($(git rev-list --count HEAD))"
tools/build-app.sh release
APP="$ROOT/build/Octomux.app"
DIST="$ROOT/dist"
mkdir -p "$DIST"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== sign with $SIGN_ID"
# Inside out: nested executables first, then the bundle. --timestamp and the hardened runtime are what
# notarization requires.
sign() { codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$@"; }
sign "$APP/Contents/Resources/bin/octomux"
# Sparkle's helpers, innermost first (as Sparkle documents for Developer ID apps).
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SP/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

notarize() {   # $1: file to submit (zip or dmg)
    [ "${OCTOMUX_SKIP_NOTARIZE:-}" = 1 ] && { echo "(notarization skipped)"; return; }
    echo "== notarize $(basename "$1") (usually a few minutes)"
    local out; out="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1)"; echo "$out"
    if ! grep -q "status: Accepted" <<<"$out"; then
        local id; id="$(sed -n 's/^ *id: //p' <<<"$out" | head -1)"
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
        echo "notarization failed" >&2; exit 1
    fi
}

# 1. The app itself, so its ticket can be stapled (works offline, and the updater zip carries it).
ditto -c -k --keepParent "$APP" "$WORK/Octomux.zip"
notarize "$WORK/Octomux.zip"
[ "${OCTOMUX_SKIP_NOTARIZE:-}" = 1 ] || xcrun stapler staple "$APP"
ZIP="$DIST/Octomux-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
# The appcast: generate_appcast signs each zip with the EdDSA key from the keychain and keeps older entries.
# Only the new version is listed: older zips sit under their own tags, and Sparkle only needs the newest.
UPD="$DIST/updates"
rm -rf "$UPD"; mkdir -p "$UPD"
cp "$ZIP" "$UPD/"
[ -f "$ROOT/CHANGELOG.md" ] && awk -v v="$VERSION" '$0 ~ "^## "v"( |$)" {on=1; next} /^## / {on=0} on' "$ROOT/CHANGELOG.md" > "$UPD/Octomux-$VERSION.md"
if [ -n "${OCTOMUX_DOWNLOAD_PREFIX:-}" ]; then
    "$SPARKLE_BIN/generate_appcast" --download-url-prefix "$OCTOMUX_DOWNLOAD_PREFIX" --maximum-deltas 0 "$UPD"
else
    "$SPARKLE_BIN/generate_appcast" --maximum-deltas 0 "$UPD"
    echo "note: OCTOMUX_DOWNLOAD_PREFIX is empty; appcast.xml links are file names only" >&2
fi

# 2. The disk image: the app and an Applications link to drag it onto.
echo "== dmg"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Octomux.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Octomux-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Octomux $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
notarize "$DMG"
[ "${OCTOMUX_SKIP_NOTARIZE:-}" = 1 ] || xcrun stapler staple "$DMG"

echo "== check"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 || true
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 || true
[ -n "${OCTOMUX_FEED_URL:-}" ] || echo "warning: OCTOMUX_FEED_URL is empty; this build does not check for updates" >&2
ls -lh "$DMG" "$ZIP" "$UPD/appcast.xml"
