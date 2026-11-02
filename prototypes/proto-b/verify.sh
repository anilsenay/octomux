#!/bin/bash
# Headless-ish verification for proto-b. Starts its own daemon under /tmp/adeb,
# creates two terminal sessions, drives them through `ade ctl session.input`,
# and screenshots the proto-b window. Cleans up everything it started.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ADE="$REPO/core/target/debug/ade"
APP="$HERE/target/debug/proto-b"
SHOTS="$REPO/screenshots"
export ADE_HOME=/tmp/adeb
DUMP=/tmp/adeb-dump
mkdir -p "$SHOTS" /tmp/adeb-proj
rm -rf "$ADE_HOME" "$DUMP"
mkdir -p "$ADE_HOME"

(cd "$REPO/core" && cargo build -q) || exit 1
(cd "$HERE" && cargo build -q --features selfshot) || exit 1

APP_PID=""; DAEMON_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
  "$ADE" ctl daemon.shutdown '{}' >/dev/null 2>&1
  sleep 0.5
  for f in "$ADE_HOME"/run/*.json; do
    [ -f "$f" ] || continue
    pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$f" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
}
trap cleanup EXIT

ctl() { "$ADE" ctl "$1" "$2"; }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1"; }
input() { ctl session.input "{\"id\":\"$1\",\"data\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")}" >/dev/null; }
screen() { ctl session.screen_text "{\"id\":\"$1\"}" | jget "['text']"; }

"$ADE" daemon >"$ADE_HOME/daemon.out" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 50); do [ -S "$ADE_HOME/run/daemon.sock" ] && break; sleep 0.1; done

WS=$(ctl state.get '{}' | jget "['workspaces'][0]['id']")
PROJ=$(ctl project.create "{\"workspace_id\":\"$WS\",\"path\":\"/tmp/adeb-proj\"}" | jget "['id']")
S1=$(ctl session.create "{\"project_id\":\"$PROJ\",\"cols\":80,\"rows\":24}" | jget "['session']['id']")
S2=$(ctl session.create "{\"project_id\":\"$PROJ\",\"cols\":80,\"rows\":24}" | jget "['session']['id']")
echo "sessions: $S1 $S2"

# Deterministic shells regardless of the user's zsh config.
for S in $S1 $S2; do input "$S" $'exec /bin/sh\r'; done
sleep 0.5
input "$S1" $'PS1=\'left$ \'; clear; printf \'\\033[1mbold\\033[0m \\033[31mred\\033[0m \\033[42;30mgreen-bg\\033[0m \\033[7minverse\\033[0m \\033[38;5;208m256-orange\\033[0m \\033[38;2;120;200;255mtruecolor\\033[0m\\n\'; ls -la /tmp/adeb-proj\r'
input "$S2" $'PS1=\'right$ \'; clear; printf \'T\\303\\274rk\\303\\247e: \\303\\247 \\304\\237 \\304\\261 \\303\\266 \\305\\237 \\303\\274 \\303\\207 \\304\\236 \\304\\260 \\303\\226 \\305\\236 \\303\\234\\n\'; echo \'echo-utf8: ılık şöğüç İSTANBUL\'\r'
sleep 1

shot() { # $1 name. Real window capture first; GPUI offscreen render as fallback.
  local wid out="$SHOTS/proto-b-$1.png"
  rm -f "$out"
  wid=$(swift "$HERE/winid.swift" proto-b | awk '{print $1}')
  if [ -n "$wid" ] && screencapture -x -o -l "$wid" "$out" 2>/dev/null && [ -s "$out" ]; then
    echo "shot $1 via screencapture (window $wid)"; return 0
  fi
  echo "$out" > "$DUMP/shot-request"
  for _ in $(seq 30); do [ -s "$out" ] && break; sleep 0.1; done
  [ -s "$out" ] && echo "shot $1 via GPUI render_to_image (screencapture unavailable)" || echo "shot $1 FAILED"
}
compare() { # client parser text vs holder text
  for S in $S1 $S2; do
    if [ -f "$DUMP/$S.txt" ]; then
      if diff <(screen "$S" | sed 's/[[:space:]]*$//') <( (cat "$DUMP/$S.txt"; echo) | sed "s/[[:space:]]*$//") >/dev/null; then
        echo "  $S: client grid == holder grid"
      else
        echo "  $S: MISMATCH"; diff <(screen "$S") "$DUMP/$S.txt" | head -10
      fi
    fi
  done
}
launch() {
  PROTO_B_DUMP_DIR=$DUMP PROTO_B_RESIZE="${1:-}" "$APP" "$ADE_HOME" "$S1" "$S2" >"$ADE_HOME/app.out" 2>&1 &
  APP_PID=$!
  sleep 3
}

echo "== 1. shell + colors + turkish"
launch
shot 1-shell; compare

echo "== 2. vim alt screen"
input "$S1" $'vim -u NONE /tmp/adeb-proj/x.txt\r'
sleep 1
input "$S1" $'iHello from vim — çğıöşü\x1b:set number\r'
sleep 1
shot 2-vim; compare
ctl session.screen_text "{\"id\":\"$S1\"}" | jget "['alt']"

echo "== 3. kill and relaunch app (reattach)"
cp "$DUMP/$S1.txt" /tmp/adeb-before.txt
kill "$APP_PID"; wait "$APP_PID" 2>/dev/null; APP_PID=""
rm -rf "$DUMP"
launch
shot 3-reattach; compare
diff -q /tmp/adeb-before.txt "$DUMP/$S1.txt" && echo "  reattach: left pane identical to before kill"

echo "== 4. resize window"
kill "$APP_PID"; wait "$APP_PID" 2>/dev/null; APP_PID=""
launch "2500:800x450,6000:1400x800"
sleep 0.5
shot 4a-small; compare
ctl state.get '{}' >/dev/null
sleep 3.5
input "$S1" $'\x1b:q!\r'
sleep 0.5
input "$S1" $'stty size\r'; input "$S2" $'stty size\r'
sleep 1
shot 4b-large; compare
tail -5 "$ADE_HOME/app.out"
