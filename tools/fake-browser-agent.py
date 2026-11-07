#!/usr/bin/env python3
"""Drives the Octomux browser the way an agent does: starts `octomux mcp --session <id>` and talks MCP to it.

usage: fake-browser-agent.py <session-id> <url> [--shot out.png] [--steps navigate,snapshot,type,click,screenshot]
Env: OCTOMUX_HOME (the fixture world), OCTOMUX_BIN (the CLI; default core/target/debug/octomux).
The page is expected to have a textbox and a button (tools/browser-test-page.html). Exits non-zero on a failed step.
"""
import base64, json, os, re, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bin_ = os.environ.get("OCTOMUX_BIN") or os.path.join(root, "core/target/debug/octomux")
args = sys.argv[1:]
session, url = args[0], args[1]
shot = args[args.index("--shot") + 1] if "--shot" in args else None
steps = (args[args.index("--steps") + 1] if "--steps" in args else "navigate,snapshot,type,click,screenshot").split(",")

p = subprocess.Popen([bin_, "mcp", "--session", session], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
seq = 0

def rpc(method, params=None):
    global seq
    seq += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": seq, "method": method, "params": params or {}}) + "\n")
    p.stdin.flush()
    r = json.loads(p.stdout.readline())
    if "error" in r:
        sys.exit(f"{method}: {r['error']}")
    return r["result"]

def call(name, **arguments):
    r = rpc("tools/call", {"name": name, "arguments": arguments})
    text = "\n".join(c["text"] for c in r["content"] if c["type"] == "text")
    print(f"=== {name} {json.dumps(arguments)}{' (ERROR)' if r.get('isError') else ''} [{len(text)} chars]")
    print(text[:3000])
    if r.get("isError") and not os.environ.get("FAKE_AGENT_CONTINUE"):
        sys.exit(1)
    return r, text

def ref(snapshot, pattern):
    m = re.search(pattern + r'[^\n]*?\[ref=(\w+)\]', snapshot)
    if not m:
        sys.exit(f"no element matching {pattern!r} in the snapshot")
    return m.group(1)

info = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fake", "version": "0"}})
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
tools = [t["name"] for t in rpc("tools/list")["tools"]]
print("server:", info["serverInfo"], "tools:", len(tools))

snap = full = ""
for step in steps:
    if step == "navigate":
        _, snap = call("browser_navigate", url=url)
    elif step == "snapshot":
        _, snap = call("browser_snapshot")
    elif step == "type":
        _, snap = call("browser_type", element="Email field", ref=ref(snap, r'textbox "Email"'), text="agent@example.com")
    elif step == "click":
        _, snap = call("browser_click", element="Create account button", ref=ref(snap, r'button "Create account"'))
        if "Submitted: agent@example.com" not in snap:
            sys.exit("the click didn't submit the form")
    elif step == "screenshot":
        r, _ = call("browser_take_screenshot")
        img = [c for c in r["content"] if c["type"] == "image"]
        if not img:
            sys.exit("no image in the screenshot result")
        if shot:
            open(shot, "wb").write(base64.b64decode(img[0]["data"]))
            print("saved", shot, img[0]["mimeType"])
    elif step == "tabs":
        call("browser_tabs", action="list")
    elif step == "console":
        call("browser_console_messages")
    elif step == "back":
        _, snap = call("browser_navigate_back")
    elif step.startswith("wait:"):
        _, snap = call("browser_wait_for", text=step[5:])
    elif step.startswith("eval:"):
        call("browser_evaluate", function=step[5:])
    elif step.startswith("key:"):
        _, snap = call("browser_press_key", key=step[4:])
    elif step.startswith("press:"):     # press:<pattern in the last whole snapshot>, e.g. press:button "Add an item"
        _, out = call("browser_click", element=step[6:], ref=ref(full, re.escape(step[6:])))
        snap = out
    elif step.startswith("resize:"):
        _, snap = call("browser_resize", preset=step[7:])
    elif step == "snapdiff":
        _, snap = call("browser_snapshot", diff=True)
    elif step.startswith("goto:"):
        _, snap = call("browser_navigate", url=step[5:])
    if "### Snapshot\n" in snap:
        full = snap
p.stdin.close()
p.wait()
print("OK")
