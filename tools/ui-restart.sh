#!/bin/bash
# Restarts the debug app against the fixture world (ADE_HOME=/tmp/adeU).
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ADE_HOME=${ADE_HOME:-/tmp/adeU} ADE_DEBUG=1 ADE_BIN=$ROOT/core/target/debug/ade
[ -f /tmp/adeU-app.pid ] && kill "$(cat /tmp/adeU-app.pid)" 2>/dev/null; sleep 0.5
nohup "$ROOT/app/.build/debug/ADE" > /tmp/adeU-app.log 2>&1 & echo $! > /tmp/adeU-app.pid
for i in $(seq 1 40); do "$ROOT/tools/dbg" ping >/dev/null 2>&1 && break; sleep 0.25; done
"$ROOT/tools/dbg" resize_window "{\"width\":${W:-1320},\"height\":${H:-820}}" >/dev/null
sleep 1.5
