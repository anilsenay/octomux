#!/bin/bash
# Removes ONLY what the overnight (pre-rename ADE) resume tests left in your Claude configs:
# the project entry "/private/tmp/aded-claude" and its transcript folders.
# Backups are written next to each file (*.octomux-backup).
set -euo pipefail
for f in ~/.claude.json ~/.claude-work/.claude.json ~/.claude/.claude.json; do
  [ -f "$f" ] || continue
  cp "$f" "$f.octomux-backup"
  python3 - "$f" <<'EOF'
import json, os, sys, tempfile
f = sys.argv[1]
d = json.load(open(f))
removed = [k for k in list(d.get("projects", {})) if k == "/private/tmp/aded-claude"]
for k in removed:
    del d["projects"][k]
if removed:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f)); os.close(fd)
    st = os.stat(f)
    with open(tmp, "w") as o:
        json.dump(d, o, indent=2)
    os.chmod(tmp, st.st_mode & 0o777)
    os.replace(tmp, f)
print(f.replace(os.path.expanduser("~"), "~"), "removed:", removed or "nothing")
EOF
done
rm -rf ~/.claude/projects/-private-tmp-aded-claude ~/.claude-work/projects/-private-tmp-aded-claude
echo "Leftovers (should be empty):"
ls -d ~/.claude*/projects/*aded* 2>/dev/null || true
grep -l "aded-claude" ~/.claude.json ~/.claude-work/.claude.json ~/.claude/.claude.json 2>/dev/null || true
