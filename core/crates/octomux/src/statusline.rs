//! `ade statusline`: the status line command we inject with `--settings` (Claude Code, and agy, whose payload
//! says `"product": "antigravity"`).
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
    let sid = octomux_proto::env_var_os("SESSION_ID").and_then(|v| v.into_string().ok());
    if v.get("product").and_then(|p| p.as_str()) == Some("antigravity") {
        return antigravity(paths, sid.as_deref(), &v, &input);
    }
    if let (Some(sid), Some(rl)) = (sid.as_deref(), v.get("rate_limits")) {
        report(paths, sid, rl);
    }
    if let (Some(sid), Some(ctx)) = (sid.as_deref(), v.get("context_window")) {
        write_context(paths, sid, ctx, v.pointer("/model/display_name"));
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

/// The session's context usage for the app's chat view (`run/<sid>.context`), rewritten when it changes.
fn write_context(paths: &Paths, sid: &str, ctx: &Value, model: Option<&Value>) {
    if sid.is_empty() || sid.contains('/') || sid.contains("..") {
        return;
    }
    let body = serde_json::json!({ "context_window": ctx, "model": model }).to_string();
    let path = paths.run_dir().join(format!("{sid}.context"));
    if std::fs::read_to_string(&path).is_ok_and(|s| s == body) {
        return;
    }
    let tmp = path.with_extension("context.tmp");
    if std::fs::write(&tmp, &body).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
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

/// agy: its conversation and transcript (exact, unlike reading its index), its Gemini quota as usage limits, the
/// context for the chat view; then the user's own agy status line, else one like agy's built-in.
fn antigravity(paths: &Paths, sid: Option<&str>, v: &Value, input: &str) -> i32 {
    if let Some(sid) = sid.filter(|s| !s.is_empty() && !s.contains('/') && !s.contains("..")) {
        if let Some(conv) = v.get("conversation_id").or_else(|| v.get("session_id")).and_then(|x| x.as_str()) {
            report_agent(paths, sid, conv, v.get("transcript_path").and_then(|x| x.as_str()));
        }
        if let Some(q) = v.get("quota") {
            let rl = antigravity_limits(q, SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0));
            if rl.as_object().is_some_and(|o| !o.is_empty()) {
                report(paths, sid, &rl);
            }
        }
        if let Some(ctx) = v.get("context_window") {
            write_context(paths, sid, ctx, v.pointer("/model/display_name"));
        }
    }
    match antigravity_user_command() {
        Some(cmd) => passthrough(&cmd, input),
        None => {
            println!("{}", antigravity_line(v));
            0
        }
    }
}

/// agy's `quota` (`gemini-5h`: {remaining_fraction, reset_in_seconds}) in Claude's `rate_limits` shape, the
/// windows the app knows (five_hour, seven_day). Third-party model pools are left out; a window without a reset
/// (agy sends 1970) has none.
pub fn antigravity_limits(q: &Value, now: i64) -> Value {
    let mut out = serde_json::Map::new();
    for (src, dst) in [("gemini-5h", "five_hour"), ("gemini-weekly", "seven_day")] {
        let Some(w) = q.get(src) else { continue };
        let Some(rem) = w.get("remaining_fraction").and_then(|x| x.as_f64()) else { continue };
        let used = ((1.0 - rem) * 1000.0).round() / 10.0;
        let reset = w.get("reset_in_seconds").and_then(|x| x.as_i64()).filter(|s| *s > 0).map(|s| now + s);
        out.insert(dst.into(), serde_json::json!({ "used_percentage": used.clamp(0.0, 100.0), "resets_at": reset }));
    }
    Value::Object(out)
}

/// Tells the daemon the session's conversation once it changes (`/new`, `/resume` switch it).
fn report_agent(paths: &Paths, sid: &str, conv: &str, transcript: Option<&str>) {
    let stamp = paths.run_dir().join(format!("{sid}.agent"));
    let body = format!("{conv}\n{}", transcript.unwrap_or(""));
    if std::fs::read_to_string(&stamp).is_ok_and(|s| s == body) {
        return;
    }
    if let Ok(mut c) = client::Control::connect(paths) {
        c.set_timeout(Some(Duration::from_millis(800)));
        if c.call("agent.report", serde_json::json!({ "session_id": sid, "agent_session_id": conv, "transcript_path": transcript })).is_ok() {
            let _ = std::fs::write(&stamp, &body);
        }
    }
}

/// The user's own `statusLine` command in agy's settings (read only; ours is never saved there).
fn antigravity_user_command() -> Option<String> {
    let f = crate::util::home_dir().join(".gemini/antigravity-cli/settings.json");
    let v: Value = serde_json::from_str(&std::fs::read_to_string(f).ok()?).ok()?;
    let cmd = v.pointer("/statusLine/command").and_then(|c| c.as_str())?;
    (!cmd.contains(" statusline")).then(|| cmd.to_string())
}

/// Like agy's own line: `auto · Gemini 4 Neon · high`.
fn antigravity_line(v: &Value) -> String {
    let mode = v.get("cycle_mode").and_then(|x| x.as_str()).unwrap_or("");
    let name = v.pointer("/model/display_name").and_then(|x| x.as_str()).unwrap_or("");
    let effort = v.pointer("/model/effort").and_then(|x| x.as_str()).unwrap_or("");
    // "Gemini 4 Neon (High)" → "Gemini 4 Neon": the effort follows on its own.
    let model = match name.rfind(" (") {
        Some(i) if !effort.is_empty() && name.ends_with(')') => &name[..i],
        _ => name,
    };
    [mode, model, effort].iter().filter(|s| !s.is_empty()).copied().collect::<Vec<_>>().join(" · ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn antigravity_quota_reads_as_usage_limits() {
        let q = serde_json::json!({
            "3p-5h": { "remaining_fraction": 1, "reset_in_seconds": 0 },
            "gemini-5h": { "remaining_fraction": 0.9786068, "reset_in_seconds": 17425 },
            "gemini-weekly": { "remaining_fraction": 0.5, "reset_in_seconds": 0 }
        });
        let rl = antigravity_limits(&q, 1000);
        assert_eq!(rl["five_hour"]["used_percentage"], 2.1);
        assert_eq!(rl["five_hour"]["resets_at"], 18425);
        assert_eq!(rl["seven_day"]["used_percentage"], 50.0);
        assert!(rl["seven_day"]["resets_at"].is_null());
        assert_eq!(rl.as_object().unwrap().len(), 2);
    }

    #[test]
    fn antigravity_default_line() {
        let v = serde_json::json!({ "cycle_mode": "auto", "model": { "display_name": "Gemini 4 Neon (High)", "effort": "high" } });
        assert_eq!(antigravity_line(&v), "auto · Gemini 4 Neon · high");
        assert_eq!(antigravity_line(&serde_json::json!({ "model": { "display_name": "Gemini 4 Flash" } })), "Gemini 4 Flash");
    }
}
