#!/bin/bash
# Builds libghostty (GhosttyKit.xcframework) at the pinned commit into vendor/. Needs Zig 0.17 and Xcode
# with the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`). Takes a few minutes; run once.
# GHOSTTY_TARGET: universal (default, arm64 + x86_64, what releases ship) or native (this Mac only, faster).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY_COMMIT=7cd6fa0215a1299c69c27fe543f48ecab45b775f   # 2026-11-02; bump deliberately, then rebuild and test
cd "$ROOT"
mkdir -p vendor
if [ ! -d vendor/ghostty/.git ]; then
    git clone https://github.com/ghostty-org/ghostty.git vendor/ghostty
fi
cd vendor/ghostty
if [ "$(git rev-parse HEAD)" != "$GHOSTTY_COMMIT" ]; then
    git fetch --quiet origin "$GHOSTTY_COMMIT" 2>/dev/null || git fetch --quiet origin
    git checkout --quiet "$GHOSTTY_COMMIT"
fi
zig build -Demit-xcframework=true -Dxcframework-target="${GHOSTTY_TARGET:-universal}" \
    -Demit-macos-app=false -Demit-docs=false -Doptimize=ReleaseFast
rm -rf "$ROOT/vendor/GhosttyKit.xcframework"
mv macos/GhosttyKit.xcframework "$ROOT/vendor/"
echo "built vendor/GhosttyKit.xcframework (ghostty $GHOSTTY_COMMIT)"
