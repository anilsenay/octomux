#!/bin/bash
# Builds build/ADE.app (Swift app + bundled `ade` CLI). Usage: tools/build-app.sh [debug|release]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${1:-release}"
cd "$ROOT/core"
if [ "$CONF" = release ]; then cargo build --release -q; ADE="$ROOT/core/target/release/ade"; else cargo build -q; ADE="$ROOT/core/target/debug/ade"; fi
cd "$ROOT/app"
if [ "$CONF" = release ]; then swift build -c release 2>&1 | grep -E "error|warning: unre" || true; BIN="$(swift build -c release --show-bin-path)/ADE";
else swift build 2>&1 | grep -E "error" || true; BIN="$(swift build --show-bin-path)/ADE"; fi
APP="$ROOT/build/ADE.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN" "$APP/Contents/MacOS/ADE"
cp "$ADE" "$APP/Contents/Resources/bin/ade"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.ade-dev.app</string>
  <key>CFBundleName</key><string>ADE</string>
  <key>CFBundleDisplayName</key><string>ADE</string>
  <key>CFBundleExecutable</key><string>ADE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP/Contents/Resources/bin/ade" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
