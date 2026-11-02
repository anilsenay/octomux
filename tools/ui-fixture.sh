#!/bin/bash
# Builds a throwaway ADE world for UI screenshots: ADE_HOME=/tmp/adeU, three git projects,
# fake agents in working / input / done states, a dock action. Never touches prod data.
# usage: tools/ui-fixture.sh            (prints the env to export; then start the app with ADE_DEBUG=1)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ADE_HOME=${ADE_HOME:-/tmp/adeU}
ADE=${ADE_BIN:-$ROOT/core/target/debug/ade}
P=/tmp/adeU-proj
"$ADE" ctl daemon.shutdown >/dev/null 2>&1 || true
pkill -f "holder.*$ADE_HOME" 2>/dev/null || true
rm -rf "$ADE_HOME" "$P"; mkdir -p "$P"
for name in new-ade cimri-web dotfiles; do
  d=$P/$name; mkdir -p "$d/src"; cd "$d"; git init -q -b main
  printf 'fn main() {}\n' > src/main.rs; printf '# %s\n' "$name" > README.md
  git add -A; git -c user.email=t@t -c user.name=t commit -qm init
done
cd $P/new-ade && printf 'fn main() { println!("hi"); }\n// more\n' > src/main.rs && printf 'new\n' > src/usage.rs
cd $P/cimri-web && git checkout -qb dev
j() { "$ADE" ctl "$@"; }
ws=$(j state.get | python3 -c 'import sys,json; print(json.load(sys.stdin)["workspaces"][0]["id"])')
mkproj() { j project.create "{\"workspace_id\":\"$ws\",\"path\":\"$P/$1\",\"color\":\"$2\"}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("id") or d["project"]["id"])'; }
p1=$(mkproj new-ade "#EF8C39"); p2=$(mkproj cimri-web "#459CF7"); p3=$(mkproj dotfiles "#39C363")
FA=$ROOT/tools/fake-agent.sh
pid_of() { j state.get | python3 -c "import sys,json; print([p['id'] for p in json.load(sys.stdin)['profiles'] if p['name'].lower()=='$1'.lower()][0])"; }
# Point the default profiles at the fake agent (fixture only).
j profile.update "{\"id\":\"$(pid_of Claude)\",\"kind\":\"generic\",\"command\":\"$FA\",\"args\":[\"working\"]}" >/dev/null
j profile.update "{\"id\":\"$(pid_of Codex)\",\"kind\":\"generic\",\"command\":\"$FA\",\"args\":[\"done\"]}" >/dev/null
work=$(j profile.create "{\"name\":\"Claude (work)\",\"icon\":\"claude\",\"kind\":\"generic\",\"command\":\"$FA\",\"pinned\":true,\"args\":[\"input\"],\"env\":{},\"resume_template\":\"\"}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
agent() {
  local id; id=$(j session.create "{\"project_id\":\"$1\",\"profile_id\":\"$2\",\"placement\":\"tab\",\"cols\":120,\"rows\":36}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["session"]["id"])')
  j session.rename "{\"id\":\"$id\",\"title\":\"$3\"}" >/dev/null
}
term() { j session.create "{\"project_id\":\"$1\",\"placement\":\"${2:-tab}\",\"cols\":120,\"rows\":36}" >/dev/null; }
agent "$p1" "$(pid_of Claude)" "Refactor holder snapshot"
agent "$p1" "$work" "Review PR #42"
term "$p1"
agent "$p2" "$work" "Fix checkout test"
agent "$p2" "$(pid_of Codex)" "Bump deps"
j session.create "{\"project_id\":\"$p1\",\"command\":\"printf 'running 18 tests\\\\ntest reboot_restore ... ok\\\\ntest vim_alt_screen ... ok\\\\ntest result: ok. 18 passed\\\\n'\",\"title\":\"Test\",\"placement\":\"dock\",\"cols\":120,\"rows\":12}" >/dev/null
j settings.set "{\"scope\":\"project:$p1\",\"key\":\"actions\",\"value\":[{\"name\":\"Test\",\"icon\":\"flask\",\"command\":\"cargo test\"},{\"name\":\"Dev\",\"icon\":\"play.fill\",\"command\":\"npm run dev\"}]}" >/dev/null
# Fake usage readings through the real statusline path.
sid_of() { j state.get | python3 -c "import sys,json; print([s['id'] for s in json.load(sys.stdin)['sessions'] if s.get('custom_title')=='$1'][0])"; }
now=$(date +%s)
feed() { printf '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' "$2" $((now+8040)) "$3" $((now+302400)) \
  | ADE_SESSION_ID=$(sid_of "$1") CLAUDE_CONFIG_DIR=/nonexistent "$ADE" statusline >/dev/null; }
feed "Refactor holder snapshot" 42 18
feed "Review PR #42" 76 31
j settings.set "{\"scope\":\"global\",\"key\":\"usage.always_show\",\"value\":[\"$work\"]}" >/dev/null
echo "export ADE_HOME=$ADE_HOME"
