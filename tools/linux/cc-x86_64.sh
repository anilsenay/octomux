#!/bin/sh
args=""
for a in "$@"; do
  case "$a" in --target=*|-Wl,--as-needed|-Wl,--fix-cortex-a53-843419) ;; *) args="$args '$(printf %s "$a" | sed "s/'/'\\\\''/g")'" ;; esac
done
eval exec zig cc -target x86_64-linux-gnu.2.28 $args
