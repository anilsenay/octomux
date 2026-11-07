//! `octomux mcp`: a stdio MCP server that agents (Claude Code, Codex) start for their session. It gives them the
//! Octomux browser: every tool call is passed to the app over `run/browser.sock`, which drives the page the user
//! can watch in the Browser panel. The tool list is fixed here so an agent sees it even before the app is open.

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

pub fn run(paths: &Paths, session: Option<String>) -> anyhow::Result<i32> {
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
        if let Some(reply) = handle(&msg, &mut |tool, args| call_app(paths, session.as_deref(), tool, args)) {
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
                "instructions": INSTRUCTIONS,
            })
        }
        "ping" => json!({}),
        "tools/list" => json!({ "tools": tools() }),
        "tools/call" => {
            let name = msg.pointer("/params/name").and_then(|v| v.as_str()).unwrap_or("");
            let args = msg.pointer("/params/arguments").cloned().unwrap_or_else(|| json!({}));
            if !tools().iter().any(|t| t["name"] == name) {
                return Some(json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32602, "message": format!("unknown tool: {name}") } }));
            }
            call(name, &args)
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

const INSTRUCTIONS: &str = "Octomux browser: a real web browser inside the Octomux app that the user watches live in its Browser panel. \
Use it to open and check web pages (local dev servers, docs, the app you are building): navigate, read the page with browser_snapshot, \
act on elements by their ref from the latest snapshot, and take screenshots to check how things look. Pages keep cookies between \
sessions, so sites the user signed in to stay signed in; don't sign in, buy, post or send anything unless the user asked you to.";

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

/// The browser tools, named and shaped like the common agent browser tools so models know them.
pub fn tools() -> Vec<Value> {
    let (element, r#ref) = element_ref();
    let read_only = json!({ "readOnlyHint": true });
    vec![
        json!({
            "name": "browser_navigate",
            "description": "Open a URL in the current page (creates a page if there is none). Returns the page snapshot.",
            "inputSchema": obj(json!({ "url": s("The URL to open (http, https, file, or a bare host like localhost:3000).") }), &["url"]),
        }),
        json!({
            "name": "browser_navigate_back",
            "description": "Go back to the previous page in the current page's history.",
            "inputSchema": obj(json!({}), &[]),
        }),
        json!({
            "name": "browser_snapshot",
            "description": "Read the current page as an accessibility snapshot (roles, names, text) with a ref for each element you can act on. Better than a screenshot for finding and using elements.",
            "inputSchema": obj(json!({
                "depth": { "type": "number", "description": "Only this many levels of the tree (for a quick overview of a large page)." },
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
        for n in ["browser_navigate", "browser_snapshot", "browser_click", "browser_type", "browser_take_screenshot", "browser_tabs"] {
            assert!(names.contains(&n), "{n}");
        }
        for t in r["result"]["tools"].as_array().unwrap() {
            assert_eq!(t["inputSchema"]["type"], "object", "{}", t["name"]);
        }
        let r = handle(&rpc("nope", json!({})), &mut never).unwrap();
        assert_eq!(r["error"]["code"], -32601);
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
