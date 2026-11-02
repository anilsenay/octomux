#!/usr/bin/env python3
"""Fake Claude Code for UI fixtures: writes a Claude-format transcript under $CLAUDE_CONFIG_DIR and
answers each line typed into the session with an echo (so the chat view round trip can be tested).
Never calls a model."""
import json, os, re, sys, time, uuid

args = sys.argv[1:]
sid = args[args.index("--session-id") + 1] if "--session-id" in args else (args[args.index("--resume") + 1] if "--resume" in args else str(uuid.uuid4()))
cfg = os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("/tmp/fake-claude"))
d = os.path.join(cfg, "projects", "-" + os.getcwd().strip("/").replace("/", "-"))
os.makedirs(d, exist_ok=True)
path = os.path.join(d, sid + ".jsonl")
resumed = os.path.exists(path)

def w(entry):
    entry.setdefault("uuid", str(uuid.uuid4()))
    entry.setdefault("timestamp", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    entry["sessionId"] = sid
    with open(path, "a") as f:
        f.write(json.dumps(entry) + "\n")

def status(s):
    sys.stdout.write("\x1b]7501;state=%s:app=fake-claude\x07" % s); sys.stdout.flush()

O, G, D, B, N = "\x1b[38;5;209m", "\x1b[32m", "\x1b[90m", "\x1b[1m", "\x1b[0m"
sys.stdout.write("\x1b]2;Refactor holder snapshot\x07")
print(f"{O}✻ {B}Fake Claude{N}{D}  {os.getcwd()}  session {sid[:8]}{N}\n")
if not resumed:
    w({"type": "user", "message": {"role": "user", "content": "snapshot should replay the main screen before the alt screen"}})
    w({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "thinking", "thinking": "The holder must capture the main screen when the program switches to the alternate screen, then replay it first on attach."},
        {"type": "text", "text": "I'll look at how the holder builds its snapshot."},
        {"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": os.path.join(os.getcwd(), "core/crates/ade/src/holder.rs")}}]}})
    w({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "pub fn snapshot_bytes(...) {\n    // replay history, then the screen\n}"}]}})
    w({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "t2", "name": "Edit", "input": {"file_path": os.path.join(os.getcwd(), "core/crates/ade/src/holder.rs")}}]}})
    w({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t2", "content": "Updated with 18 additions and 4 removals"}]}})
    w({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "t3", "name": "Bash", "input": {"command": "cargo test -p ade", "description": "Run tests"}}]}})
    w({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t3", "content": "test result: ok. 26 passed; 0 failed"}]}})
    w({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text":
        "Done. The holder now **captures the main screen** right before the alternate screen is entered and replays it first, so reattaching while `vim` runs keeps your shell history.\n\nTests: `cargo test -p ade` — 26 passed."}]}})
print(f"{G}⏺{N} Done. The holder now captures the main screen before the alt screen.\n")
print(f"{D}(type a message; this fake echoes it){N}")
status("done")
for line in sys.stdin:
    text = re.sub(r"\x1b\[20[01]~", "", line).strip()
    if not text:
        continue
    status("working")
    w({"type": "user", "message": {"role": "user", "content": text}})
    time.sleep(0.6)
    reply = f"Echo from the fake agent: **{text}**"
    w({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": reply}]}})
    print(f"{G}⏺{N} {reply}")
    status("done")
