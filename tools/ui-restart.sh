#!/bin/bash
# Restarts the debug app against the fixture world (OCTOMUX_HOME=/tmp/octomuxU).
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export OCTOMUX_HOME=${OCTOMUX_HOME:-/tmp/octomuxU} OCTOMUX_DEBUG=1 OCTOMUX_BIN=$ROOT/core/target/debug/octomux
"$ROOT/tools/sign-debug.sh"
[ -f /tmp/octomuxU-app.pid ] && kill "$(cat /tmp/octomuxU-app.pid)" 2>/dev/null; sleep 0.5
nohup "$ROOT/app/.build/debug/Octomux" > /tmp/octomuxU-app.log 2>&1 & echo $! > /tmp/octomuxU-app.pid
for i in $(seq 1 40); do "$ROOT/tools/dbg" ping >/dev/null 2>&1 && break; sleep 0.25; done
"$ROOT/tools/dbg" resize_window "{\"width\":${W:-1320},\"height\":${H:-820}}" >/dev/null
sleep 1.5
