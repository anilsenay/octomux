//! `ade statusline`: the Claude Code status line command we inject with `--settings`.
//! 1. Reports `rate_limits` from the payload to the daemon (throttled, bounded, never fails).
//! 2. Passes the same payload to the user's own status line command and prints its output,
//!    so their status line looks exactly as before. Without one, prints a short default line.

use crate::client;
use octomux_proto::Paths;
use serde_json::Value;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

const MIN_INTERVAL: Duration = Duration::from_secs(15);

pub fn run(paths: &Paths) -> i32 {
    let mut input = String::new();
    let _ = std::io::stdin().take(4 << 20).read_to_string(&mut input);
    let v: Value = serde_json::from_str(&input).unwrap_or(Value::Null);
    if let (Some(sid), Some(rl)) = (octomux_proto::env_var_os("SESSION_ID").and_then(|v| v.into_string().ok()), v.get("rate_limits")) {
        report(paths, &sid, rl);
    }
    let cwd = v.pointer("/workspace/current_dir").or_else(|| v.get("cwd")).and_then(|x| x.as_str()).map(PathBuf::from);
    match user_command(cwd.as_deref()) {
        Some(cmd) => passthrough(&cmd, &input),
        None => {
            println!("{}", default_line(&v));
            0
        }
    }
}

/// Sends a reading when it changed, at most every 15 s per session.
fn report(paths: &Paths, sid: &str, rl: &Value) {
    let stamp = paths.run_dir().join(format!("{sid}.usage"));
    let body = rl.to_string();
    if let Ok(meta) = std::fs::metadata(&stamp) {
        let fresh = meta.modified().ok().and_then(|m| SystemTime::now().duration_since(m).ok()).is_some_and(|age| age < MIN_INTERVAL);
        let same = std::fs::read_to_string(&stamp).is_ok_and(|s| s == body);
        if fresh || (same && meta.modified().ok().and_then(|m| SystemTime::now().duration_since(m).ok()).is_some_and(|a| a < Duration::from_secs(120))) {
            return;
        }
    }
    let _ = std::fs::write(&stamp, &body);
    if let Ok(mut c) = client::Control::connect(paths) {
        c.set_timeout(Some(Duration::from_millis(800)));
        let _ = c.call("usage.report", serde_json::json!({ "session_id": sid, "rate_limits": rl }));
    }
}

/// The user's own statusLine command: project-local, project, then user settings of the
/// active config dir (read only). Ignores our own command to avoid recursion.
pub fn user_command(cwd: Option<&std::path::Path>) -> Option<String> {
    let mut files: Vec<PathBuf> = Vec::new();
    if let Some(d) = cwd {
        files.push(d.join(".claude/settings.local.json"));
        files.push(d.join(".claude/settings.json"));
    }
    let cfg = std::env::var("CLAUDE_CONFIG_DIR").map(PathBuf::from).unwrap_or_else(|_| crate::util::home_dir().join(".claude"));
    files.push(cfg.join("settings.json"));
    for f in files {
        let Ok(text) = std::fs::read_to_string(&f) else { continue };
        let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
        if let Some(cmd) = v.pointer("/statusLine/command").and_then(|c| c.as_str()) {
            if !cmd.contains(" statusline") || !(cmd.contains("octomux") || cmd.contains("ade")) {
                return Some(cmd.to_string());
            }
        }
    }
    None
}

fn passthrough(cmd: &str, input: &str) -> i32 {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
    let child = std::process::Command::new(shell)
        .arg("-c")
        .arg(cmd)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .spawn();
    let Ok(mut child) = child else { return 0 };
    if let Some(mut si) = child.stdin.take() {
        let _ = si.write_all(input.as_bytes());
    }
    child.wait().ok().and_then(|s| s.code()).unwrap_or(0)
}

fn default_line(v: &Value) -> String {
    let model = v.pointer("/model/display_name").and_then(|x| x.as_str()).unwrap_or("");
    let ctx = v.pointer("/context_window/used_percentage").and_then(|x| x.as_f64());
    match (model.is_empty(), ctx) {
        (false, Some(c)) => format!("{model} · {c:.0}% context"),
        (false, None) => model.to_string(),
        (true, Some(c)) => format!("{c:.0}% context"),
        (true, None) => String::new(),
    }
}
