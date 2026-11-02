#!/bin/bash
# UI polish pass: main window, project-row hover actions, collapsed sidebar + peek, dock positions,
# in dark/light × wide/narrow → screenshots/v-*.png. Fixture world only (/tmp/adeU).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
export ADE_HOME=/tmp/adeU
ADE=$ROOT/core/target/debug/ade
OUT=${OUT:-$ROOT/screenshots}
q() { $ADE ctl state.get | python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
dbg() { tools/dbg "$@" >/dev/null 2>&1; }
shot() { tools/dbg screenshot "{\"path\":\"$OUT/$1\"}" >/dev/null; }
P1=$(q '[p["id"] for p in d["projects"] if p["name"]=="new-ade"][0]')
SID=$(q '[s["id"] for s in d["sessions"] if s.get("custom_title")=="Refactor holder snapshot"][0]')
for mode in ${MODES:-dark light}; do
  $ADE ctl settings.set "{\"scope\":\"global\",\"key\":\"appearance.mode\",\"value\":\"$mode\"}" >/dev/null
  for size in ${SIZES:-wide narrow}; do
    if [ $size = wide ]; then W=1320 H=820; else W=900 H=640; fi
    W=$W H=$H tools/ui-restart.sh
    tag=$mode-$size
    dbg ui_action "{\"name\":\"select_session\",\"id\":\"$SID\"}"; sleep 0.8
    dbg ui_action "{\"name\":\"hover_project\",\"id\":\"$P1\"}"; sleep 0.6
    shot v-main-$tag.png
    dbg ui_action '{"name":"hover_project"}'
    for pos in bottom right; do
      dbg ui_action "{\"name\":\"dock_position\",\"value\":\"$pos\"}"
      dbg ui_action '{"name":"toggle_dock"}'; sleep 1.2; shot v-dock-$pos-$tag.png; dbg ui_action '{"name":"toggle_dock"}'; sleep 0.4
    done
    dbg ui_action '{"name":"dock_position","value":"bottom"}'
    dbg ui_action '{"name":"toggle_sidebar"}'; sleep 0.8; shot v-collapsed-$tag.png
    dbg ui_action '{"name":"sidebar_peek","value":true}'; sleep 0.8; tools/dbg screenshot "{\"path\":\"$OUT/v-peek-$tag.png\",\"children\":true}" >/dev/null
    dbg ui_action '{"name":"sidebar_peek","value":false}'; dbg ui_action '{"name":"toggle_sidebar"}'; sleep 0.4
  done
done
