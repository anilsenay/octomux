//! `octomux mcp`: a stdio MCP server that agents (Claude Code, Codex) start for their session. It gives them the
//! Octomux browser: every tool call is passed to the app over `run/browser.sock`, which drives the page the user
//! can watch in the Browser panel. The tool list is fixed here so an agent sees it even before the app is open.
//!
//! It also gives them Octomux tasks (`task_*`) and, for the workspace assistant, the sessions of its tasks
//! (`session_*`). Those calls go to the daemon (`mcp.call`), which applies the rules for agents. The caller is
//! the session given with `--session` (agents we launch get it in their MCP config), else `$OCTOMUX_SESSION_ID`.

use octomux_proto::Paths;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

/// Newest MCP revision we speak; older ones a client asks for are accepted as is (we only use tools).
const LATEST_PROTOCOL: &str = "2025-06-18";
const KNOWN_PROTOCOLS: &[&str] = &["2024-11-05", "2025-03-26", "2025-06-18"];

pub fn socket_path(paths: &Paths) -> std::path::PathBuf {
    paths.run_dir().join("browser.sock")
}

pub fn run(paths: &Paths, session: Option<String>, browser: bool) -> anyhow::Result<i32> {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(msg) = serde_json::from_str::<Value>(&line) else {
            write_msg(&mut out, &json!({ "jsonrpc": "2.0", "id": null, "error": { "code": -32700, "message": "parse error" } }))?;
            continue;
        };
        let mut call = |tool: &str, args: &Value| {
            if is_daemon_tool(tool) { call_daemon(paths, session.as_deref(), tool, args) } else { call_app(paths, session.as_deref(), tool, args) }
        };
        if let Some(reply) = handle_with(&msg, &mut call, browser) {
            write_msg(&mut out, &reply)?;
        }
    }
    Ok(0)
}

fn write_msg(out: &mut impl Write, v: &Value) -> std::io::Result<()> {
    let mut s = serde_json::to_string(v)?;
    s.push('\n');
    out.write_all(s.as_bytes())?;
    out.flush()
}

/// One JSON-RPC message in, at most one reply out (notifications get none).
pub fn handle(msg: &Value, call: &mut dyn FnMut(&str, &Value) -> Value) -> Option<Value> {
    handle_with(msg, call, true)
}

/// `browser` false (`--no-browser`: the user browses with another tool): only the task and session tools.
pub fn handle_with(msg: &Value, call: &mut dyn FnMut(&str, &Value) -> Value, browser: bool) -> Option<Value> {
    let id = msg.get("id").cloned();
    let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let id = id?; // notifications (initialized, cancelled, …) need no answer
    let result = match method {
        "initialize" => {
            let asked = msg.pointer("/params/protocolVersion").and_then(|v| v.as_str()).unwrap_or(LATEST_PROTOCOL);
            let version = if KNOWN_PROTOCOLS.contains(&asked) { asked } else { LATEST_PROTOCOL };
            json!({
                "protocolVersion": version,
                "capabilities": { "tools": {} },
                "serverInfo": { "name": "octomux", "title": "Octomux", "version": env!("CARGO_PKG_VERSION") },
                "instructions": if browser { format!("{BROWSER_INSTRUCTIONS} {TASK_INSTRUCTIONS}") } else { TASK_INSTRUCTIONS.to_string() },
            })
        }
        "ping" => json!({}),
        "tools/list" => json!({ "tools": tools_for(browser) }),
        "tools/call" => {
            let name = msg.pointer("/params/name").and_then(|v| v.as_str()).unwrap_or("");
            let args = msg.pointer("/params/arguments").cloned().unwrap_or_else(|| json!({}));
            let Some(tool) = tools_for(browser).into_iter().find(|t| t["name"] == name) else {
                return Some(json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32602, "message": format!("unknown tool: {name}") } }));
            };
            // The app checks the browser tools' arguments itself.
            match is_daemon_tool(name).then(|| check_args(&tool["inputSchema"], &args)) {
                Some(Err(e)) => error_result(&e),
                _ => call(name, &args),
            }
        }
        "resources/list" => json!({ "resources": [] }),
        "prompts/list" => json!({ "prompts": [] }),
        _ => return Some(json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": format!("method not found: {method}") } })),
    };
    Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }))
}

fn error_result(text: &str) -> Value {
    json!({ "content": [{ "type": "text", "text": text }], "isError": true })
}

/// Tools the daemon answers (tasks and the assistant's session tools); the rest go to the app's browser.
pub fn is_daemon_tool(name: &str) -> bool {
    name.starts_with("task_") || name.starts_with("session_")
}

/// Checks arguments against a tool's input schema: required ones present, no unknown ones, simple types and enums.
pub fn check_args(schema: &Value, args: &Value) -> Result<(), String> {
    let Some(args) = args.as_object() else { return Err("arguments must be an object".into()) };
    let props = schema["properties"].as_object().cloned().unwrap_or_default();
    for r in schema["required"].as_array().into_iter().flatten().filter_map(|r| r.as_str()) {
        if args.get(r).is_none_or(|v| v.is_null()) {
            return Err(format!("missing argument {r}"));
        }
    }
    for (k, v) in args {
        let Some(p) = props.get(k) else { return Err(format!("unknown argument {k}")) };
        let ok = match p["type"].as_str() {
            Some("string") => v.is_string() || v.is_null(),
            Some("number") => v.is_number(),
            Some("boolean") => v.is_boolean(),
            _ => true,
        };
        if !ok {
            return Err(format!("{k} must be a {}", p["type"].as_str().unwrap_or("value")));
        }
        if let Some(allowed) = p["enum"].as_array()
            && !v.is_null()
            && !allowed.contains(v)
        {
            let names: Vec<&str> = allowed.iter().filter_map(|a| a.as_str()).collect();
            return Err(format!("{k} must be one of {}", names.join(", ")));
        }
    }
    Ok(())
}

/// Sends a task/session tool call to the daemon and returns its MCP `CallToolResult`.
fn call_daemon(paths: &Paths, session: Option<&str>, tool: &str, args: &Value) -> Value {
    let Some(session) = session else {
        return error_result("Octomux doesn't know which session this agent runs in (no --session or OCTOMUX_SESSION_ID), so its task tools aren't available.");
    };
    let mut c = match crate::client::Control::connect(paths) {
        Ok(c) => c,
        Err(_) => return error_result("Octomux isn't running, so its tasks aren't available. Try again later."),
    };
    c.set_timeout(Some(Duration::from_secs(20)));
    match c.call("mcp.call", json!({ "session": session, "tool": tool, "args": args })) {
        Ok(Value::String(s)) => json!({ "content": [{ "type": "text", "text": s }] }),
        Ok(v) => json!({ "content": [{ "type": "text", "text": serde_json::to_string_pretty(&v).unwrap_or_default() }] }),
        Err(e) => error_result(&format!("{e:#}")),
    }
}

/// Sends one call to the app and returns its MCP `CallToolResult`. A fresh connection per call, so an app
/// restart between calls doesn't matter.
fn call_app(paths: &Paths, session: Option<&str>, tool: &str, args: &Value) -> Value {
    let sock = socket_path(paths);
    let mut stream = match UnixStream::connect(&sock) {
        Ok(s) => s,
        Err(_) => return error_result("The Octomux app isn't open (or runs on another Mac), so its browser isn't available. Ask the user to open Octomux, then try again."),
    };
    // Navigations and waits are bounded on the app side; this only guards against a hung app.
    let _ = stream.set_read_timeout(Some(Duration::from_secs(180)));
    let req = json!({ "tool": tool, "args": args, "session": session });
    let mut line = req.to_string();
    line.push('\n');
    if stream.write_all(line.as_bytes()).is_err() {
        return error_result("Couldn't reach the Octomux browser. Try again.");
    }
    let mut reply = String::new();
    match BufReader::new(stream).read_line(&mut reply) {
        Ok(n) if n > 0 => serde_json::from_str::<Value>(&reply).unwrap_or_else(|_| error_result("The Octomux browser sent a reply that couldn't be read.")),
        _ => error_result("The Octomux browser didn't answer (the app may have quit). Try again."),
    }
}

const BROWSER_INSTRUCTIONS: &str = "Octomux browser: a real web browser inside the Octomux app that the user watches live in its Browser panel. \
Use it to open and check web pages (local dev servers, docs, the app you are building): navigate, read the page with browser_snapshot, \
act on elements by their ref from the latest snapshot, and take screenshots to check how things look. After each action the result \
says what changed (address, title, new pages, downloads, console errors) and shows the page: a newly opened page whole when it is small, \
else as an outline (landmarks, headings, links, buttons, fields); after a click or typing, only the lines that changed (marked so). Pages keep cookies between sessions, so sites the user signed in to stay signed in; don't sign in, \
buy, post or send anything unless the user asked you to.";
const TASK_INSTRUCTIONS: &str = "Octomux tasks: the user's work items in Octomux (not Jira or GitHub issues). task_list and task_get read them; task_create adds a \
planned task (or a subtask with parent_id); task_update changes a task's title, description or state (planned, working, \
ready_to_review, done). Only a workspace assistant uses task_start and the session_* tools, for the sessions of tasks it owns.";

fn s(desc: &str) -> Value {
    json!({ "type": "string", "description": desc })
}

fn element_ref() -> (Value, Value) {
    (
        s("Short human-readable description of the element, shown to the user watching (e.g. \"Sign in button\")."),
        s("Exact ref of the element from the latest page snapshot (e.g. \"e12\")."),
    )
}

fn obj(props: Value, required: &[&str]) -> Value {
    json!({ "type": "object", "properties": props, "required": required, "additionalProperties": false })
}

/// Every tool: the browser's, then the task and session ones.
pub fn tools() -> Vec<Value> {
    tools_for(true)
}

fn tools_for(browser: bool) -> Vec<Value> {
    let mut v = if browser { browser_tools() } else { vec![] };
    v.extend(task_tools());
    v
}

fn task_tools() -> Vec<Value> {
    let read_only = json!({ "readOnlyHint": true });
    let id = s("Task id.");
    let project = s("Project id (default: the project of your session).");
    vec![
        json!({
            "name": "task_create",
            "description": "Add an Octomux task (or a subtask of a top-level task). It starts as planned; the user or the assistant decides when it is worked on. Returns the task.",
            "inputSchema": obj(json!({
                "title": s("Short title."),
                "description": s("What needs doing, in a few lines (markdown)."),
                "parent_id": s("Make it a subtask of this task (one level only: the parent can't be a subtask)."),
                "project_id": project,
            }), &["title"]),
        }),
        json!({
            "name": "task_list",
            "description": "List the Octomux tasks of your session's project (or another project of its workspace).",
            "inputSchema": obj(json!({
                "state": { "type": "string", "enum": ["planned", "working", "needs_you", "ready_to_review", "in_review", "done"], "description": "Only tasks in this state." },
                "project_id": project,
            }), &[]),
            "annotations": read_only,
        }),
        json!({
            "name": "task_get",
            "description": "One Octomux task with all its fields (sessions, branch, worktree, PR, parent).",
            "inputSchema": obj(json!({ "id": id }), &["id"]),
            "annotations": read_only,
        }),
        json!({
            "name": "task_update",
            "description": "Change a task's title, description or state. Set ready_to_review when your work on it is finished and ready for the user to look at.",
            "inputSchema": obj(json!({
                "id": id,
                "title": s("New title."),
                "description": s("New description (replaces the old one)."),
                "state": { "type": "string", "enum": ["planned", "working", "ready_to_review", "done"], "description": "New state." },
            }), &["id"]),
        }),
        json!({
            "name": "task_start",
            "description": "Workspace assistant: ask Octomux to start an agent on a planned task. The app decides (it may ask the user); returns \"requested\".",
            "inputSchema": obj(json!({ "id": id }), &["id"]),
        }),
        json!({
            "name": "session_summary",
            "description": "Workspace assistant: state, activity, title, folder and last activity time of a session working on one of your tasks.",
            "inputSchema": obj(json!({ "session_id": s("Session id (from the task's sessions).") }), &["session_id"]),
            "annotations": read_only,
        }),
        json!({
            "name": "session_send",
            "description": "Workspace assistant: send a message to the agent in a session working on one of your tasks. It is typed into the session, marked as from the assistant, and submitted.",
            "inputSchema": obj(json!({
                "session_id": s("Session id (from the task's sessions)."),
                "text": s("The message."),
            }), &["session_id", "text"]),
        }),
    ]
}

/// The browser tools, named and shaped like the common agent browser tools so models know them.
fn browser_tools() -> Vec<Value> {
    let (element, r#ref) = element_ref();
    let read_only = json!({ "readOnlyHint": true });
    vec![
        json!({
            "name": "browser_navigate",
            "description": "Open a URL in the current page (creates a page if there is none). Returns the page: whole when it is small, else an outline of its landmarks, headings, links, buttons and fields with their refs (browser_snapshot reads the whole page).",
            "inputSchema": obj(json!({ "url": s("The URL to open (http, https, file, or a bare host like localhost:3000).") }), &["url"]),
        }),
        json!({
            "name": "browser_navigate_back",
            "description": "Go back to the previous page in the current page's history. Returns the page like browser_navigate.",
            "inputSchema": obj(json!({}), &[]),
        }),
        json!({
            "name": "browser_snapshot",
            "description": "Read the current page as an accessibility snapshot (roles, names, text) with a ref for each element you can act on. Better than a screenshot for finding and using elements.",
            "inputSchema": obj(json!({
                "depth": { "type": "number", "description": "Only this many levels of the tree (for a quick overview of a large page)." },
                "diff": { "type": "boolean", "description": "Only what changed since your last snapshot of this page (+ new or changed lines, - gone ones, under their parents)." },
            }), &[]),
            "annotations": read_only,
        }),
        json!({
            "name": "browser_click",
            "description": "Click an element of the page.",
            "inputSchema": obj(json!({
                "element": element, "ref": r#ref,
                "doubleClick": { "type": "boolean", "description": "Double-click instead of a single click." },
                "button": { "type": "string", "enum": ["left", "right", "middle"], "description": "Mouse button (default left)." },
            }), &["element", "ref"]),
        }),
        json!({
            "name": "browser_type",
            "description": "Type text into an editable element (input, textarea, contenteditable). Replaces what it holds.",
            "inputSchema": obj(json!({
                "element": element, "ref": r#ref,
                "text": s("Text to type."),
                "submit": { "type": "boolean", "description": "Press Enter afterwards." },
                "slowly": { "type": "boolean", "description": "Type one character at a time (for pages that react to each key)." },
            }), &["element", "ref", "text"]),
        }),
        json!({
            "name": "browser_press_key",
            "description": "Press a key on the focused element, e.g. Enter, Escape, Tab, ArrowDown, Backspace, a, or a combination like Control+a.",
            "inputSchema": obj(json!({ "key": s("Key name or character, optionally with modifiers joined by +.") }), &["key"]),
        }),
        json!({
            "name": "browser_hover",
            "description": "Move the mouse over an element.",
            "inputSchema": obj(json!({ "element": element, "ref": r#ref }), &["element", "ref"]),
        }),
        json!({
            "name": "browser_select_option",
            "description": "Choose option(s) in a <select>.",
            "inputSchema": obj(json!({
                "element": element, "ref": r#ref,
                "values": { "type": "array", "items": { "type": "string" }, "description": "Option values or labels to select." },
            }), &["element", "ref", "values"]),
        }),
        json!({
            "name": "browser_take_screenshot",
            "description": "Take a screenshot of the visible part of the page (or the whole page, or one element). Use browser_snapshot to find elements; screenshots are for checking how the page looks.",
            "inputSchema": obj(json!({
                "fullPage": { "type": "boolean", "description": "The whole scrollable page instead of the visible part." },
                "element": s("Description of the element to capture (with ref)."),
                "ref": s("Ref of an element to capture instead of the page."),
            }), &[]),
            "annotations": read_only,
        }),
        json!({
            "name": "browser_wait_for",
            "description": "Wait until a text appears or disappears on the page, or for a number of seconds.",
            "inputSchema": obj(json!({
                "text": s("Text to wait for."),
                "textGone": s("Text to wait to disappear."),
                "time": { "type": "number", "description": "Seconds to wait (at most 30)." },
            }), &[]),
        }),
        json!({
            "name": "browser_evaluate",
            "description": "Run a JavaScript function in the page and return its result as JSON. Example: () => document.title, or (element) => element.textContent with a ref.",
            "inputSchema": obj(json!({
                "function": s("A JavaScript function: () => { … } or (element) => { … } when a ref is given. May be async."),
                "element": s("Description of the element passed to the function."),
                "ref": s("Ref of the element passed to the function."),
            }), &["function"]),
        }),
        json!({
            "name": "browser_console_messages",
            "description": "The page's console messages and uncaught errors since it was loaded.",
            "inputSchema": obj(json!({}), &[]),
            "annotations": read_only,
        }),
        json!({
            "name": "browser_resize",
            "description": "Lay the page out at a screen size, to check a mobile or tablet layout: a preset (mobile 390×844 and tablet 820×1180 also send a phone/tablet user agent, laptop 1280×800, desktop 1920×1080, fit = the browser's own size) or width and height. Returns the new size, not the page: take a screenshot or a snapshot to see it.",
            "inputSchema": obj(json!({
                "preset": { "type": "string", "enum": ["mobile", "tablet", "laptop", "desktop", "fit"], "description": "A screen size preset." },
                "width": { "type": "number", "description": "Width in CSS pixels (with height, instead of a preset)." },
                "height": { "type": "number", "description": "Height in CSS pixels." },
            }), &[]),
        }),
        json!({
            "name": "browser_tabs",
            "description": "List, open, select or close browser pages. Each session works in its own current page; list shows every page, including the user's and other sessions'.",
            "inputSchema": obj(json!({
                "action": { "type": "string", "enum": ["list", "new", "select", "close"], "description": "What to do." },
                "page": s("Page id from the list (for select and close; close defaults to the current page)."),
                "url": s("URL to open in the new page (for new)."),
            }), &["action"]),
        }),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rpc(method: &str, params: Value) -> Value {
        json!({ "jsonrpc": "2.0", "id": 7, "method": method, "params": params })
    }

    #[test]
    fn handshake_and_tools() {
        let mut never = |_: &str, _: &Value| -> Value { panic!("no call expected") };
        let r = handle(&rpc("initialize", json!({ "protocolVersion": "2025-03-26", "capabilities": {} })), &mut never).unwrap();
        assert_eq!(r["id"], 7);
        assert_eq!(r["result"]["protocolVersion"], "2025-03-26");
        assert!(r["result"]["capabilities"]["tools"].is_object());
        let r = handle(&rpc("initialize", json!({ "protocolVersion": "2099-01-01" })), &mut never).unwrap();
        assert_eq!(r["result"]["protocolVersion"], LATEST_PROTOCOL);
        assert!(handle(&json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }), &mut never).is_none());
        let r = handle(&rpc("tools/list", json!({})), &mut never).unwrap();
        let names: Vec<&str> = r["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        for n in ["browser_navigate", "browser_snapshot", "browser_click", "browser_type", "browser_take_screenshot", "browser_tabs", "browser_resize"] {
            assert!(names.contains(&n), "{n}");
        }
        for t in r["result"]["tools"].as_array().unwrap() {
            assert_eq!(t["inputSchema"]["type"], "object", "{}", t["name"]);
        }
        let r = handle(&rpc("nope", json!({})), &mut never).unwrap();
        assert_eq!(r["error"]["code"], -32601);
        assert!(r_text(&handle(&rpc("initialize", json!({})), &mut never).unwrap()).contains("Octomux browser"));
    }

    fn r_text(r: &Value) -> String {
        r["result"]["instructions"].as_str().unwrap_or("").to_string()
    }

    #[test]
    fn without_the_browser() {
        let mut never = |_: &str, _: &Value| -> Value { panic!("no call expected") };
        let r = handle_with(&rpc("initialize", json!({})), &mut never, false).unwrap();
        assert!(!r_text(&r).contains("browser") && r_text(&r).contains("Octomux tasks"), "{}", r_text(&r));
        let r = handle_with(&rpc("tools/list", json!({})), &mut never, false).unwrap();
        let names: Vec<&str> = r["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"task_list") && !names.iter().any(|n| n.starts_with("browser_")), "{names:?}");
        let r = handle_with(&rpc("tools/call", json!({ "name": "browser_navigate", "arguments": { "url": "x" } })), &mut never, false).unwrap();
        assert_eq!(r["error"]["code"], -32602);
    }

    #[test]
    fn calls_are_relayed() {
        let mut seen = Vec::new();
        let mut call = |name: &str, args: &Value| {
            seen.push((name.to_string(), args.clone()));
            json!({ "content": [{ "type": "text", "text": "ok" }] })
        };
        let r = handle(&rpc("tools/call", json!({ "name": "browser_click", "arguments": { "ref": "e3", "element": "Go" } })), &mut call).unwrap();
        assert_eq!(r["result"]["content"][0]["text"], "ok");
        let r = handle(&rpc("tools/call", json!({ "name": "rm_rf", "arguments": {} })), &mut call).unwrap();
        assert_eq!(r["error"]["code"], -32602);
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].0, "browser_click");
        assert_eq!(seen[0].1["ref"], "e3");
    }

    #[test]
    fn task_tools_are_listed_next_to_the_browser() {
        let mut never = |_: &str, _: &Value| -> Value { panic!("no call expected") };
        let r = handle(&rpc("tools/list", json!({})), &mut never).unwrap();
        let names: Vec<&str> = r["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        for n in ["browser_navigate", "task_create", "task_list", "task_get", "task_update", "task_start", "session_summary", "session_send"] {
            assert!(names.contains(&n), "{n}");
        }
        assert!(names.iter().all(|n| is_daemon_tool(n) != n.starts_with("browser_")), "{names:?}");
        let update = r["result"]["tools"].as_array().unwrap().iter().find(|t| t["name"] == "task_update").unwrap().clone();
        assert_eq!(update["inputSchema"]["properties"]["state"]["enum"], json!(["planned", "working", "ready_to_review", "done"]));
    }

    #[test]
    fn task_tool_arguments_are_checked_before_the_call() {
        let mut calls = 0;
        let mut call = |_: &str, _: &Value| {
            calls += 1;
            json!({ "content": [{ "type": "text", "text": "ok" }] })
        };
        let mut tool = |name: &str, args: Value| handle(&rpc("tools/call", json!({ "name": name, "arguments": args })), &mut call).unwrap();
        for (name, args, says) in [
            ("task_create", json!({}), "missing argument title"),
            ("task_create", json!({ "title": "x", "state": "working" }), "unknown argument state"),
            ("task_create", json!({ "title": 5 }), "title must be a string"),
            ("task_update", json!({ "id": "t", "state": "in_review" }), "state must be one of"),
            ("task_list", json!({ "state": "later" }), "state must be one of"),
            ("session_send", json!({ "session_id": "s" }), "missing argument text"),
            ("task_get", json!("t1"), "must be an object"),
        ] {
            let r = tool(name, args);
            assert_eq!(r["result"]["isError"], true, "{name}");
            let text = r["result"]["content"][0]["text"].as_str().unwrap();
            assert!(text.contains(says), "{name}: {text}");
        }
        assert_eq!(tool("task_update", json!({ "id": "t", "state": "done", "title": "T" }))["result"]["content"][0]["text"], "ok");
        // Browser tools go through as before (the app checks them).
        assert_eq!(tool("browser_click", json!({ "anything": 1 }))["result"]["content"][0]["text"], "ok");
        drop(tool);
        assert_eq!(calls, 2);
    }

    #[test]
    fn task_tools_need_a_session_and_a_daemon() {
        let dir = std::env::temp_dir().join(format!("octomux-mcp-task-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("run")).unwrap();
        let paths = Paths { home: dir.clone() };
        let r = call_daemon(&paths, None, "task_list", &json!({}));
        assert_eq!(r["isError"], true);
        assert!(r["content"][0]["text"].as_str().unwrap().contains("which session"));
        let r = call_daemon(&paths, Some("s1"), "task_list", &json!({}));
        assert_eq!(r["isError"], true);
        assert!(r["content"][0]["text"].as_str().unwrap().contains("isn't running"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn app_not_open_is_a_tool_error() {
        let dir = std::env::temp_dir().join(format!("octomux-mcp-test-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("run")).unwrap();
        let paths = Paths { home: dir.clone() };
        let r = call_app(&paths, Some("s1"), "browser_snapshot", &json!({}));
        assert_eq!(r["isError"], true);
        assert!(r["content"][0]["text"].as_str().unwrap().contains("isn't open"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
