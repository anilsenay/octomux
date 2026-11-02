#!/usr/bin/env python3
"""Fake Codex CLI for fixtures: writes a rollout in Codex's format under $CODEX_HOME/sessions and echoes
each line typed into the session. Never calls a model."""
import json, os, re, sys, time, uuid
home = os.environ.get("CODEX_HOME", "/tmp/fake-codex")
sid = str(uuid.uuid4())
d = os.path.join(home, "sessions", time.strftime("%Y/%m/%d"))
os.makedirs(d, exist_ok=True)
path = os.path.join(d, "rollout-%s-%s.jsonl" % (time.strftime("%Y-%m-%dT%H-%M-%S"), sid))
def w(t, payload):
    with open(path, "a") as f:
        f.write(json.dumps({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "type": t, "payload": payload}) + "\n")
def msg(role, text):
    w("response_item", {"type": "message", "role": role, "content": [{"type": "input_text" if role == "user" else "output_text", "text": text}]})
w("session_meta", {"id": sid, "cwd": os.getcwd(), "cli_version": "fake"})
msg("user", "<environment_context>cwd</environment_context>")
msg("user", "bump the dependencies and run the tests")
w("response_item", {"type": "reasoning", "summary": [{"type": "summary_text", "text": "Check Cargo.toml, update, run cargo test."}]})
w("response_item", {"type": "function_call", "name": "shell", "call_id": "c1", "arguments": json.dumps({"command": ["bash", "-lc", "cargo update && cargo test"]})})
w("response_item", {"type": "function_call_output", "call_id": "c1", "output": json.dumps({"output": "Updating crates.io index\ntest result: ok. 21 passed", "metadata": {"exit_code": 0}})})
msg("assistant", "Dependencies bumped; **all tests pass** (`cargo test`: 21 passed).")
w("event_msg", {"type": "token_count", "rate_limits": {"primary": {"used_percent": 12.0, "window_minutes": 300, "resets_at": int(time.time()) + 9000}, "secondary": {"used_percent": 40.0, "window_minutes": 10080, "resets_at": int(time.time()) + 300000}}})
sys.stdout.write("\x1b]2;Bump deps\x07")
print("\x1b[1m>_ Fake Codex\x1b[0m  (%s)\n\nDependencies bumped; all tests pass.\n" % os.getcwd())
sys.stdout.write("\x1b]7501;state=done:app=fake-codex\x07"); sys.stdout.flush()
for line in sys.stdin:
    text = re.sub(r"\x1b\[20[01]~", "", line).strip()
    if not text: continue
    msg("user", text)
    time.sleep(0.4)
    msg("assistant", "Codex echo: **%s**" % text)
    print("• Codex echo: %s" % text)
