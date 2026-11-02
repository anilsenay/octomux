set -e
export ADE_HOME=/tmp/adeL
mkdir -p /work/api && cd /work/api
ade ctl hello >/dev/null
J() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
WS=$(ade ctl state.get | J 'd["workspaces"][0]["id"]')
P=$(ade ctl project.create "{\"workspace_id\":\"$WS\",\"path\":\"/work/api\"}" | J 'd["id"]')
S=$(ade ctl session.create "{\"project_id\":\"$P\",\"cols\":80,\"rows\":24}" | J 'd["session"]["id"]')
sleep 1.5
ade ctl session.input "{\"id\":\"$S\",\"data\":\"echo LINUX-\$((6*7)) \$(uname -sm)\\r\"}" >/dev/null
sleep 1
ade ctl session.screen_text "{\"id\":\"$S\"}" | J 'd["text"]' | grep LINUX- | tail -1
echo "session=$S"
ade status | head -3
