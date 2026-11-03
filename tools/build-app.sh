#!/bin/bash
# Builds build/Octomux.app (Swift app + bundled `octomux` CLI). Usage: tools/build-app.sh [debug|release]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${1:-release}"
# Updates: OCTOMUX_FEED_URL (appcast) and OCTOMUX_ED_PUBLIC_KEY, set by release.sh. Empty (local builds) = no updater.
# Version: VERSION file (marketing) and OCTOMUX_BUILD (monotonic build number; release.sh uses the commit count).
VERSION="${OCTOMUX_VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)}"
BUILD="${OCTOMUX_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
cd "$ROOT/core"
if [ "$CONF" = release ]; then cargo build --release -q; CLI="$ROOT/core/target/release/octomux"; else cargo build -q; CLI="$ROOT/core/target/debug/octomux"; fi
cd "$ROOT/app"
if [ "$CONF" = release ]; then swift build -c release 2>&1 | grep -E "error|warning: unre" || true; BIN="$(swift build -c release --show-bin-path)/Octomux";
else swift build 2>&1 | grep -E "error" || true; BIN="$(swift build --show-bin-path)/Octomux"; fi
APP="${OCTOMUX_APP_OUT:-$ROOT/build/Octomux.app}"   # OCTOMUX_APP_OUT: another place (update tests)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN" "$APP/Contents/MacOS/Octomux"
# Sparkle (auto-update), next to the binary in SwiftPM's build dir; the binary's rpath looks in Frameworks.
mkdir -p "$APP/Contents/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$CLI" "$APP/Contents/Resources/bin/octomux"
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/app/Resources/editor" "$APP/Contents/Resources/editor"   # code viewer (CodeMirror bundle; rebuild: cd app/editor-web && bun run build)
# Ghostty terminal color schemes, for scenes' "terminal" field (from the vendored Ghostty build).
THEMES="$ROOT/vendor/ghostty/zig-out/share/ghostty/themes"
[ -d "$THEMES" ] && rm -rf "$APP/Contents/Resources/terminal-themes" && cp -R "$THEMES" "$APP/Contents/Resources/terminal-themes"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.octomux.app</string>
  <key>CFBundleName</key><string>Octomux</string>
  <key>CFBundleDisplayName</key><string>Octomux</string>
  <key>CFBundleExecutable</key><string>Octomux</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>SUFeedURL</key><string>${OCTOMUX_FEED_URL:-}</string>
  <key>SUPublicEDKey</key><string>${OCTOMUX_ED_PUBLIC_KEY:-}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>21600</integer>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP/Contents/Resources/bin/octomux" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
# Pre-rename bundle: running sessions still call its CLI from their hooks, so it is left in place.
[ -d "$ROOT/build/ADE.app" ] && echo "note: build/ADE.app (pre-rename) left in place; delete it once no session started by it is running" || true
