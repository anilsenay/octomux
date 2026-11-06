#!/usr/bin/env python3
"""Writes a Claude-format transcript that covers what the chat view draws: markdown (lists, tables, code),
thinking, grouped tool runs (Read, Grep, Glob, Bash with output, a failing command), edit diffs (Edit, MultiEdit,
Write), a todo list, a subagent, a web fetch, an MCP tool, a question and a plan, a slash command and an
interruption. usage: chat-fixture.py <out.jsonl> <cwd>   (fake-claude.py uses it when FAKE_CLAUDE_RICH=1)"""
import json, sys, uuid
from datetime import datetime, timedelta, timezone

out, cwd = sys.argv[1], sys.argv[2]
t0 = datetime.now(timezone.utc) - timedelta(minutes=30)
clock = [0]
lines = []

def w(entry, dt=4):
    clock[0] += dt
    entry.setdefault("uuid", str(uuid.uuid4()))
    entry["timestamp"] = (t0 + timedelta(seconds=clock[0])).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    lines.append(json.dumps(entry))

def user(text, dt=4): w({"type": "user", "message": {"role": "user", "content": text}}, dt)
used = [30000]
def say(*parts, dt=3):
    used[0] += 2500
    w({"type": "assistant", "message": {"role": "assistant", "model": "claude-opus-5-5", "content": list(parts),
       "usage": {"input_tokens": 12, "cache_creation_input_tokens": 800, "cache_read_input_tokens": used[0], "output_tokens": 300}}}, dt)
def text(t): return {"type": "text", "text": t}
def think(t): return {"type": "thinking", "thinking": t}
def call(i, name, inp): return {"type": "tool_use", "id": i, "name": name, "input": inp}
def result(i, content, err=False, dt=2):
    w({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": i, "content": content, "is_error": err}]}}, dt)

p = lambda rel: f"{cwd}/{rel}"

# Turn 1: exploring, a failing command, edits, tests.
user("The holder snapshot should replay the main screen before the alt screen. Can you fix it and run the tests?")
say(think("I need to find where the snapshot is built. Probably holder.rs. Then check how the alt screen switch is tracked."),
    text("I'll look at how the holder builds its snapshot first."))
say(call("r1", "Grep", {"pattern": "snapshot_bytes", "path": p("core")}))
result("r1", "core/crates/octomux/src/holder.rs:212:pub fn snapshot_bytes(&self) -> Vec<u8> {\ncore/crates/octomux/src/holder.rs:388:    let snap = self.snapshot_bytes();")
say(call("r2", "Read", {"file_path": p("core/crates/octomux/src/holder.rs"), "offset": 200, "limit": 40}))
result("r2", "   200\t/// Screen state for a client that attaches.\n   201\tpub struct Holder {\n   212\tpub fn snapshot_bytes(&self) -> Vec<u8> {\n   213\t    let mut out = self.history.clone();\n   214\t    out.extend(self.screen.render());\n   215\t    out\n   216\t}")
say(call("r3", "Glob", {"pattern": "core/crates/octomux/tests/*.rs"}))
result("r3", "core/crates/octomux/tests/integration.rs\ncore/crates/octomux/tests/holder.rs")
say(call("r4", "Bash", {"command": "cargo test -p octomux holder::alt", "description": "Run the alt screen test"}))
result("r4", "error[E0425]: cannot find value `alt_main` in this scope\n  --> core/crates/octomux/src/holder.rs:231:9\n   |\n231 |         alt_main.clear();\n   |         ^^^^^^^^ not found in this scope\n\nerror: could not compile `octomux` (lib) due to 1 previous error", err=True)
say(text("The test target doesn't compile yet; `alt_main` is referenced but never declared. I'll add the field and capture the main screen when the alt screen starts."))
say(call("e1", "Edit", {"file_path": p("core/crates/octomux/src/holder.rs"),
    "old_string": "pub struct Holder {\n    history: Vec<u8>,\n    screen: Screen,\n}",
    "new_string": "pub struct Holder {\n    history: Vec<u8>,\n    screen: Screen,\n    /// The main screen as it was when the program switched to the alternate one.\n    alt_main: Option<Vec<u8>>,\n}"}))
result("e1", "The file has been updated.")
say(call("e2", "MultiEdit", {"file_path": p("core/crates/octomux/src/holder.rs"), "edits": [
    {"old_string": "pub fn snapshot_bytes(&self) -> Vec<u8> {\n    let mut out = self.history.clone();\n    out.extend(self.screen.render());\n    out\n}",
     "new_string": "pub fn snapshot_bytes(&self) -> Vec<u8> {\n    let mut out = self.history.clone();\n    if let Some(main) = &self.alt_main {\n        out.extend(main);\n    }\n    out.extend(self.screen.render());\n    out\n}"},
    {"old_string": "fn enter_alt(&mut self) {\n    self.alt = true;\n}",
     "new_string": "fn enter_alt(&mut self) {\n    self.alt_main = Some(self.screen.render());\n    self.alt = true;\n}"}]}))
result("e2", "Applied 2 edits.")
say(call("w1", "Write", {"file_path": p("core/crates/octomux/tests/holder_alt.rs"),
    "content": "use octomux::holder::Holder;\n\n#[test]\nfn replays_main_screen_before_alt() {\n    let mut h = Holder::new(80, 24);\n    h.feed(b\"$ ls\\r\\n\");\n    h.feed(b\"\\x1b[?1049h\");\n    let snap = h.snapshot_bytes();\n    assert!(String::from_utf8_lossy(&snap).contains(\"$ ls\"));\n}\n"}))
result("w1", "File created successfully.")
say(call("b2", "Bash", {"command": "cargo test -p octomux 2>&1 | tail -3", "description": "Run tests"}))
result("b2", "running 27 tests\n" + "\n".join(f"test holder::case_{i} ... ok" for i in range(26)) + "\ntest holder_alt::replays_main_screen_before_alt ... ok\n\ntest result: ok. 27 passed; 0 failed; 0 ignored")
say(text("""Done. The holder now **captures the main screen** right before the alternate screen starts and replays it first.

What changed:

1. `Holder` keeps `alt_main`, the main screen at the moment of the switch.
2. `snapshot_bytes()` writes it before the current screen.
3. A new test, `holder_alt.rs`, covers the case.

| Check | Before | After |
|---|---|---|
| Reattach while `vim` runs | blank history | shell history kept |
| Tests | 26 passed | 27 passed |

```rust
if let Some(main) = &self.alt_main {
    out.extend(main);
}
```

> Note: `alt_main` is cleared when the program leaves the alt screen, so the snapshot never shows it twice."""), dt=6)

# Turn 2: todos, subagent, web, MCP, plan, question.
user("Now plan the scrollback limit work, check the docs for the default, and ask me which limit to use.", dt=40)
say(call("td", "TodoWrite", {"todos": [
    {"content": "Read how scrollback is stored", "status": "completed", "activeForm": "Reading how scrollback is stored"},
    {"content": "Check the default in the docs", "status": "in_progress", "activeForm": "Checking the default in the docs"},
    {"content": "Ask which limit to use", "status": "pending", "activeForm": "Asking which limit to use"},
    {"content": "Implement and test", "status": "pending", "activeForm": "Implementing"}]}))
result("td", "Todos have been modified successfully.")
say(call("ag", "Task", {"description": "Find scrollback storage", "prompt": "Find where scrollback lines are stored and how they are trimmed.", "subagent_type": "Explore"}))
result("ag", [{"type": "text", "text": "Scrollback lives in `Screen::history` (`core/crates/octomux/src/screen.rs:88`).\n\n- Lines are pushed in `scroll_up()`.\n- Nothing trims them today, so long sessions grow without bound."}], dt=20)
say(call("wf", "WebFetch", {"url": "https://example.com/docs/terminal#scrollback", "prompt": "What is the default scrollback?"}))
result("wf", "The default scrollback is 10,000 lines; it can be set with `scrollback-limit`.")
say(call("mc", "mcp__docs__search_pages", {"query": "scrollback limit"}))
result("mc", "2 pages: Terminal settings, Performance")
say(call("pl", "ExitPlanMode", {"plan": "## Scrollback limit\n\n1. Add `scrollback_limit` to settings (default **10,000** lines).\n2. Trim `Screen::history` in `scroll_up()`.\n3. Show the limit in Settings → Terminal."}))
result("pl", "User has approved your plan.")
say(call("q1", "AskUserQuestion", {"questions": [{"header": "Limit", "question": "Which scrollback limit should new sessions use?", "multiSelect": False, "options": [
    {"label": "10,000 lines", "description": "Same as most terminals"},
    {"label": "50,000 lines", "description": "More history, more memory"},
    {"label": "Unlimited", "description": "Never trim (today's behavior)"}]}]}))
result("q1", 'User has answered your questions: "Which scrollback limit should new sessions use?"="10,000 lines". You can now continue.')
say(text("Got it: **10,000 lines**. I'll implement that next."))

# Turn 3: slash command, interruption.
w({"type": "user", "message": {"role": "user", "content": "<command-name>/compact</command-name>\n<command-message>compact</command-message>"}}, dt=60)
user("Start with the settings part.", dt=10)
say(call("b3", "Bash", {"command": "rg -n scrollback core/crates/octomux/src/settings.rs"}))
w({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user for tool use]"}]}}, dt=3)

with open(out, "w") as f:
    f.write("\n".join(lines) + "\n")
