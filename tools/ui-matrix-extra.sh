#!/bin/bash
# Secondary screens in dark/light: empty project, stopped (dormant) pane, every settings page.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
export OCTOMUX_HOME=/tmp/octomuxU
CLI=$ROOT/core/target/debug/octomux; OUT=$ROOT/screenshots
q() { $CLI ctl state.get | python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
dbg() { tools/dbg "$@" >/dev/null 2>&1; }
tools/dbg ui_action '{"name":"switch_host","value":"local"}' >/dev/null 2>&1
P3=$(q '[p["id"] for p in d["projects"] if p["name"]=="dotfiles"][0]')
TERM_SID=$(q '[s["id"] for s in d["sessions"] if s["kind"]=="terminal" and s["placement"]=="tab"][0]')
for mode in dark light; do
  $CLI ctl settings.set "{\"scope\":\"global\",\"key\":\"appearance.mode\",\"value\":\"$mode\"}" >/dev/null
  tools/ui-restart.sh
  dbg ui_action "{\"name\":\"select_project\",\"id\":\"$P3\"}"; sleep 1.2
  tools/dbg screenshot "{\"path\":\"$OUT/ui-extra-empty-$mode.png\"}" >/dev/null
  dbg ui_action "{\"name\":\"select_session\",\"id\":\"$TERM_SID\"}"; dbg ui_action "{\"name\":\"stop\",\"id\":\"$TERM_SID\"}"; sleep 1.5
  tools/dbg screenshot "{\"path\":\"$OUT/ui-extra-dormant-$mode.png\"}" >/dev/null
  dbg ui_action "{\"name\":\"restart\",\"id\":\"$TERM_SID\"}"; sleep 1
  for sec in Workspaces Agents Appearance Notifications Hosts Features Keyboard Advanced; do
    dbg ui_action "{\"name\":\"open_settings\",\"value\":\"$sec\"}"; sleep 0.8
    tools/dbg screenshot_settings "{\"path\":\"$OUT/ui-extra-settings-$(echo $sec | tr A-Z a-z)-$mode.png\"}" >/dev/null
  done
  dbg ui_action '{"name":"close_settings"}'
done
echo done
