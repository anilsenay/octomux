#!/bin/bash
# Captures every phase's main screen in light/dark × wide/narrow into screenshots/<phase>-matrix-<mode>-<size>.png
# Uses the throwaway fixture worlds (/tmp/octomuxU local, /tmp/octomuxR simulated remote). Never touches prod.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
export OCTOMUX_HOME=/tmp/octomuxU
CLI=$ROOT/core/target/debug/octomux
OUT=$ROOT/screenshots
tools/ui-fixture.sh >/dev/null
# simulated remote world
mkdir -p /tmp/octomuxR-proj/api-server; git -C /tmp/octomuxR-proj/api-server init -q -b main 2>/dev/null
RWS=$(OCTOMUX_HOME=/tmp/octomuxR $CLI ctl state.get | python3 -c 'import sys,json; print(json.load(sys.stdin)["workspaces"][0]["id"])')
OCTOMUX_HOME=/tmp/octomuxR $CLI ctl state.get | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin)["projects"] else 1)' || \
  OCTOMUX_HOME=/tmp/octomuxR $CLI ctl project.create "{\"workspace_id\":\"$RWS\",\"path\":\"/tmp/octomuxR-proj/api-server\",\"color\":\"#B168D4\"}" >/dev/null
q() { $CLI ctl state.get | python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
P1=$(q '[p["id"] for p in d["projects"] if p["name"]=="octomux"][0]')
CLAUDE_SID=$(q '[s["id"] for s in d["sessions"] if s.get("custom_title")=="Refactor holder snapshot"][0]')
CODEX=$(q '[p["id"] for p in d["profiles"] if p["name"]=="Codex"][0]')
dbg() { tools/dbg "$@" >/dev/null 2>&1; }
shot() { tools/dbg screenshot "{\"path\":\"$OUT/$1\"}" >/dev/null; }
first=1
for mode in dark light; do
  $CLI ctl settings.set "{\"scope\":\"global\",\"key\":\"appearance.mode\",\"value\":\"$mode\"}" >/dev/null
  for size in wide narrow; do
    if [ $size = wide ]; then W=1320 H=820; else W=900 H=640; fi
    W=$W H=$H tools/ui-restart.sh
    if [ $first = 1 ]; then dbg ui_action "{\"name\":\"new_worktree\",\"id\":\"$P1\",\"value\":\"feat/usage-limits\",\"profile_id\":\"$CODEX\"}"; sleep 3; echo x >> /tmp/octomuxU-proj/new-ade.worktrees/feat-usage-limits/README.md; first=0; fi
    tag=$mode-$size
    dbg ui_action "{\"name\":\"select_session\",\"id\":\"$CLAUDE_SID\"}"; sleep 1
    # U: main window with dock
    dbg ui_action '{"name":"toggle_dock"}'; sleep 1.2; shot ui-matrix-$tag.png; dbg ui_action '{"name":"toggle_dock"}'
    # K: palette
    dbg ui_action '{"name":"palette","value":"split"}'; sleep 1; shot k-matrix-$tag.png; dbg ui_action '{"name":"close_palette"}'
    # L: status bar meters (bottom of main window) + popover render
    shot l-matrix-$tag.png
    tools/dbg render_view "{\"view\":\"usage\",\"dark\":$([ $mode = dark ] && echo true || echo false),\"path\":\"$OUT/l-popover-$mode.png\"}" >/dev/null
    # H: history + files
    dbg ui_action '{"name":"right_tab","value":"History"}'; sleep 1.2; dbg ui_action '{"name":"panel_select","info":{"commit":1}}'; sleep 0.8; shot h-matrix-history-$tag.png
    dbg ui_action '{"name":"right_tab","value":"Files"}'; sleep 1.2; dbg ui_action '{"name":"panel_select","info":{"file":"src/ui/theme.swift"}}'; sleep 0.8; shot h-matrix-files-$tag.png
    # W: focus the worktree session (Changes follows it)
    WT_SID=$(q '[s["id"] for s in d["sessions"] if s.get("worktree")][0]')
    dbg ui_action '{"name":"right_tab","value":"Changes"}'; dbg ui_action "{\"name\":\"select_session\",\"id\":\"$WT_SID\"}"; sleep 2; shot w-matrix-$tag.png
    dbg ui_action '{"name":"toggle_right_panel"}'
    # C: chat view
    dbg ui_action "{\"name\":\"select_session\",\"id\":\"$CLAUDE_SID\"}"; dbg ui_action "{\"name\":\"toggle_chat\",\"id\":\"$CLAUDE_SID\"}"; sleep 1.5; shot c-matrix-$tag.png
    dbg ui_action "{\"name\":\"toggle_chat\",\"id\":\"$CLAUDE_SID\"}"
    # Settings (appearance) — settings window has its own size
    dbg ui_action '{"name":"open_settings","value":"Appearance"}'; sleep 1; tools/dbg screenshot_settings "{\"path\":\"$OUT/ui-matrix-settings-$mode.png\"}" >/dev/null; dbg ui_action '{"name":"close_settings"}'
    # R: simulated remote host
    dbg ui_action "{\"name\":\"add_host\",\"value\":{\"id\":\"sim\",\"name\":\"devbox (simulated)\",\"kind\":\"command\",\"target\":\"\",\"cli\":\"$CLI\",\"prefix\":\"env OCTOMUX_HOME=/tmp/octomuxR\"}}"
    dbg ui_action '{"name":"switch_host","value":"sim"}'; sleep 3
    [ "$(OCTOMUX_HOME=/tmp/octomuxR $CLI ctl state.get | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["sessions"]))')" = 0 ] && dbg ui_action '{"name":"new_terminal"}' && sleep 2
    shot r-matrix-$tag.png
    dbg ui_action '{"name":"switch_host","value":"local"}'; sleep 2
  done
done
echo done
