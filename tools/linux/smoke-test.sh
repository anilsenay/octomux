set -e
export OCTOMUX_HOME=/tmp/octomuxL
mkdir -p /work/api && cd /work/api
octomux ctl hello >/dev/null
J() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
WS=$(octomux ctl state.get | J 'd["workspaces"][0]["id"]')
P=$(octomux ctl project.create "{\"workspace_id\":\"$WS\",\"path\":\"/work/api\"}" | J 'd["id"]')
S=$(octomux ctl session.create "{\"project_id\":\"$P\",\"cols\":80,\"rows\":24}" | J 'd["session"]["id"]')
sleep 1.5
octomux ctl session.input "{\"id\":\"$S\",\"data\":\"echo LINUX-\$((6*7)) \$(uname -sm)\\r\"}" >/dev/null
sleep 1
octomux ctl session.screen_text "{\"id\":\"$S\"}" | J 'd["text"]' | grep LINUX- | tail -1
echo "session=$S"
octomux status | head -3
