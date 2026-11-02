#!/bin/bash
# Cross-compiles `ade` for Linux with zig as C compiler/linker (glibc 2.28+).
# usage: tools/build-linux.sh [x86_64|aarch64]   → core/target/<arch>-unknown-linux-gnu/release/ade
# needs: zig, `rustup target add <arch>-unknown-linux-gnu`
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${1:-x86_64}
T=${ARCH}-unknown-linux-gnu
TV=$(echo "$T" | tr 'a-z-' 'A-Z_')
W=$ROOT/tools/linux
cat > "$W/cc-$ARCH.sh" <<CC
#!/bin/sh
args=""
for a in "\$@"; do
  case "\$a" in --target=*|-Wl,--as-needed|-Wl,--fix-cortex-a53-843419) ;; *) args="\$args '\$(printf %s "\$a" | sed "s/'/'\\\\\\\\''/g")'" ;; esac
done
eval exec zig cc -target $ARCH-linux-gnu.2.28 \$args
CC
chmod +x "$W/cc-$ARCH.sh"
export "CC_${T//-/_}=$W/cc-$ARCH.sh" "AR_${T//-/_}=$W/zigar.sh" "CARGO_TARGET_${TV}_LINKER=$W/cc-$ARCH.sh"
cd "$ROOT/core" && cargo build --release --target "$T" -p ade
echo "$ROOT/core/target/$T/release/ade"
