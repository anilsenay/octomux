//! How sessions are launched: shells, agents (Claude/Codex/generic), actions,
//! resume logic and the hook settings injected into Claude.

use crate::util::{self, expand_tilde, shell_quote};
use ade_proto::Paths;
use ade_proto::control::{AgentKind, Profile, Session, SessionKind};
use std::path::{Path, PathBuf};

pub struct LaunchSpec {
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: String,
    /// Agent session id to record (Claude ids are assigned up front).
    pub agent_session_id: Option<String>,
}

pub const HOOK_EVENTS: &[&str] =
    &["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "Notification", "SessionEnd", "PermissionRequest"];

pub fn hooks_settings_path(paths: &Paths) -> PathBuf {
    paths.agent_dir().join("claude-settings.json")
}

/// Writes the settings file passed to Claude with `--settings`. It only adds
/// hooks; the user's own settings files are never touched.
pub fn write_hook_settings(paths: &Paths) -> anyhow::Result<()> {
    util::ensure_dir_0700(&paths.agent_dir())?;
    let exe = std::env::current_exe()?.to_string_lossy().into_owned();
    let mut hooks = serde_json::Map::new();
    for ev in HOOK_EVENTS {
        let cmd = format!("{} hook {}", shell_quote(&exe), ev);
        let mut entry = serde_json::json!({ "hooks": [{ "type": "command", "command": cmd, "timeout": 5 }] });
        if matches!(*ev, "PreToolUse" | "PermissionRequest") {
            entry["matcher"] = serde_json::json!("*");
        }
        hooks.insert(ev.to_string(), serde_json::json!([entry]));
    }
    let statusline = format!("{} statusline", shell_quote(&exe));
    let doc = serde_json::json!({ "hooks": hooks, "statusLine": { "type": "command", "command": statusline, "padding": 0 } });
    std::fs::write(hooks_settings_path(paths), serde_json::to_vec_pretty(&doc)?)?;
    Ok(())
}

pub fn claude_config_dir(profile: &Profile) -> PathBuf {
    profile
        .env
        .get("CLAUDE_CONFIG_DIR")
        .map(|d| PathBuf::from(expand_tilde(d)))
        .unwrap_or_else(|| util::home_dir().join(".claude"))
}

/// Config dirs that may hold this profile's transcripts: the profile's own
/// CLAUDE_CONFIG_DIR, `~/.claude`, and any `~/.claude-*` directory.
pub fn claude_config_candidates(profile: &Profile) -> Vec<PathBuf> {
    let mut v = vec![claude_config_dir(profile)];
    for w in profile.command.split_whitespace() {
        if let Some(d) = w.strip_prefix("CLAUDE_CONFIG_DIR=") {
            v.push(PathBuf::from(expand_tilde(d)));
        }
    }
    let home = util::home_dir();
    v.push(home.join(".claude"));
    if let Ok(rd) = std::fs::read_dir(&home) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with(".claude-") && e.path().is_dir() {
                v.push(e.path());
            }
        }
    }
    v.dedup();
    v
}

/// Does Claude have a transcript for this conversation id?
pub fn claude_transcript_exists(config_dir: &Path, id: &str) -> bool {
    let projects = config_dir.join("projects");
    let Ok(rd) = std::fs::read_dir(&projects) else { return false };
    let name = format!("{id}.jsonl");
    rd.flatten().any(|e| e.path().join(&name).is_file())
}

/// Removes flags that would fight our own session handling.
pub fn strip_session_flags(args: &[String], kind: AgentKind) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        let with_value = match kind {
            AgentKind::Claude => matches!(a, "--resume" | "-r" | "--session-id" | "--settings"),
            _ => false,
        };
        let flag_only = match kind {
            AgentKind::Claude => matches!(a, "--continue" | "-c" | "--fork-session"),
            _ => false,
        };
        if with_value {
            i += 2;
            continue;
        }
        if flag_only || (kind == AgentKind::Claude && (a.starts_with("--resume=") || a.starts_with("--session-id="))) {
            i += 1;
            continue;
        }
        out.push(args[i].clone());
        i += 1;
    }
    out
}

fn codex_home(profile: &Profile) -> PathBuf {
    profile
        .env
        .get("CODEX_HOME")
        .map(|d| PathBuf::from(expand_tilde(d)))
        .unwrap_or_else(|| util::home_dir().join(".codex"))
}

/// Latest Codex rate limits from the newest rollout touched in the last 15 minutes:
/// `(window, used_percent, resets_at)`. Windows map to Claude's names by length
/// (300 min → `five_hour`, 10080 min → `seven_day`).
pub fn codex_rate_limits(profile: &Profile) -> Vec<(String, f64, Option<i64>)> {
    let root = codex_home(profile).join("sessions");
    let now = std::time::SystemTime::now();
    let mut newest: Option<(std::time::SystemTime, PathBuf)> = None;
    let mut stack = vec![root];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().and_then(|x| x.to_str()) == Some("jsonl") {
                if let Ok(m) = e.metadata().and_then(|m| m.modified()) {
                    if now.duration_since(m).map(|d| d.as_secs() < 900).unwrap_or(false) && newest.as_ref().is_none_or(|(t, _)| m > *t) {
                        newest = Some((m, p));
                    }
                }
            }
        }
    }
    let Some((_, path)) = newest else { return vec![] };
    let Ok(bytes) = std::fs::read(&path) else { return vec![] };
    let tail = &bytes[bytes.len().saturating_sub(512 * 1024)..];
    let text = String::from_utf8_lossy(tail);
    for line in text.lines().rev() {
        if !line.contains("\"rate_limits\"") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
        let Some(rl) = v.pointer("/payload/rate_limits").or_else(|| v.get("rate_limits")) else { continue };
        let mut out = vec![];
        for key in ["primary", "secondary"] {
            let Some(w) = rl.get(key).filter(|w| w.is_object()) else { continue };
            let Some(pct) = w.get("used_percent").and_then(|x| x.as_f64()) else { continue };
            let name = match w.get("window_minutes").and_then(|x| x.as_i64()) {
                Some(300) => "five_hour".to_string(),
                Some(10080) => "seven_day".to_string(),
                _ => key.to_string(),
            };
            out.push((name, pct, w.get("resets_at").and_then(|x| x.as_i64())));
        }
        return out;
    }
    vec![]
}

/// Rollout file of a Codex conversation: the one whose name contains `id`, else the newest whose
/// `session_meta.cwd` equals `cwd` and that was written after `since`.
pub fn find_rollout(codex_home: &std::path::Path, id: &str, cwd: &str, since: u64) -> Option<String> {
    let mut best: Option<(u64, PathBuf)> = None;
    let mut stack = vec![codex_home.join("sessions")];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
                continue;
            }
            let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            if !name.ends_with(".jsonl") {
                continue;
            }
            if !id.is_empty() && name.contains(id) {
                return Some(p.to_string_lossy().into_owned());
            }
            let mtime = e.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
            if mtime + 5 < since || best.as_ref().is_some_and(|(t, _)| *t >= mtime) {
                continue;
            }
            let Ok(f) = std::fs::File::open(&p) else { continue };
            let mut line = String::new();
            use std::io::BufRead;
            let _ = std::io::BufReader::new(f).read_line(&mut line);
            let meta_cwd = serde_json::from_str::<serde_json::Value>(&line).ok().and_then(|v| v.pointer("/payload/cwd").and_then(|c| c.as_str()).map(String::from));
            let same = meta_cwd.is_some_and(|c| {
                let canon = |s: &str| std::fs::canonicalize(s).map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| s.to_string());
                canon(&c) == canon(cwd)
            });
            if same {
                best = Some((mtime, p));
            }
        }
    }
    best.map(|(_, p)| p.to_string_lossy().into_owned())
}

/// Finds the newest Codex rollout for `cwd` created after `since` (seconds).
pub fn discover_codex_session(profile: &Profile, cwd: &str, since: u64) -> Option<String> {
    let root = codex_home(profile).join("sessions");
    let mut best: Option<(u64, String)> = None;
    let mut stack = vec![root];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
                continue;
            }
            if p.extension().and_then(|x| x.to_str()) != Some("jsonl") {
                continue;
            }
            let mtime = e
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            if mtime + 5 < since {
                continue;
            }
            let Ok(f) = std::fs::File::open(&p) else { continue };
            let mut line = String::new();
            use std::io::BufRead;
            if std::io::BufReader::new(f).read_line(&mut line).is_err() {
                continue;
            }
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
            let payload = v.get("payload").unwrap_or(&v);
            let (Some(id), Some(c)) = (payload.get("id").and_then(|x| x.as_str()), payload.get("cwd").and_then(|x| x.as_str())) else {
                continue;
            };
            if c == cwd && best.as_ref().is_none_or(|(t, _)| mtime > *t) {
                best = Some((mtime, id.to_string()));
            }
        }
    }
    best.map(|(_, id)| id)
}

/// Runs a command line through the user's *login* shell. Deliberately not `-i`:
/// interactive rc files can hang or swallow `-c` without a real terminal (seen with
/// shell integrations). PATH comes from [`login_shell_path`] and aliases are expanded
/// by us (see `expand_alias`).
fn login_shell_argv(cmdline: &str) -> Vec<String> {
    vec![util::user_shell(), "-l".into(), "-c".into(), cmdline.to_string()]
}

/// If `command` is one of the user's aliases, returns its text so it can be used
/// verbatim in a `-c` line (e.g. `CLAUDE_CONFIG_DIR=~/.claude-work claude`).
fn expand_alias<'a>(command: &str, aliases: &'a [(String, String)]) -> Option<&'a str> {
    if command.contains('/') || command.contains(' ') {
        return None;
    }
    aliases.iter().find(|(k, _)| k == command).map(|(_, v)| v.as_str())
}

pub fn build_launch(paths: &Paths, session: &Session, profile: Option<&Profile>, restoring: bool, aliases: &[(String, String)]) -> LaunchSpec {
    let cwd = session.cwd.clone();
    let mut env = vec![("ADE_HOME".to_string(), paths.home.to_string_lossy().into_owned())];
    match session.kind {
        SessionKind::Terminal => LaunchSpec { argv: vec![], env, cwd, agent_session_id: None },
        // After a crash/reboot an action comes back as a plain shell: never re-run
        // a command (tests, deploys…) behind the user's back.
        SessionKind::Action if restoring => LaunchSpec { argv: vec![], env, cwd, agent_session_id: None },
        SessionKind::Action => {
            // Run the command, then keep an interactive shell so the output stays visible.
            let shell = util::user_shell();
            let line = format!("{}; exec {} -l", session.command, shell_quote(&shell));
            LaunchSpec { argv: login_shell_argv(&line), env, cwd, agent_session_id: None }
        }
        SessionKind::Agent => {
            let Some(profile) = profile else {
                return LaunchSpec { argv: vec![], env, cwd, agent_session_id: None };
            };
            for (k, v) in &profile.env {
                env.push((k.clone(), expand_tilde(v)));
            }
            let mut args = strip_session_flags(&profile.args, profile.kind);
            let mut agent_id = session.agent_session_id.clone();
            let mut generic_resume: Option<String> = None;
            match profile.kind {
                AgentKind::Claude => {
                    let id = agent_id.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
                    // The profile may set CLAUDE_CONFIG_DIR through an alias or wrapper we
                    // cannot see, so look in every likely config dir.
                    if claude_config_candidates(profile).iter().any(|cfg| claude_transcript_exists(cfg, &id)) {
                        args.extend(["--resume".into(), id.clone()]);
                    } else {
                        args.extend(["--session-id".into(), id.clone()]);
                    }
                    args.extend(["--settings".into(), hooks_settings_path(paths).to_string_lossy().into_owned()]);
                    agent_id = Some(id);
                }
                AgentKind::Codex => {
                    if restoring && agent_id.is_none() {
                        agent_id = discover_codex_session(profile, &session.cwd, session.created_at);
                    }
                    if restoring {
                        if let Some(id) = &agent_id {
                            args.extend(["resume".into(), id.clone()]);
                        }
                    }
                }
                AgentKind::Generic => {
                    if restoring && !profile.resume_template.trim().is_empty() {
                        let t = profile.resume_template.replace("{id}", agent_id.as_deref().unwrap_or(""));
                        // Allow templates that start with an alias name.
                        let first = t.split_whitespace().next().unwrap_or("").to_string();
                        generic_resume = Some(match expand_alias(&first, aliases) {
                            Some(text) => format!("{text}{}", &t[first.len()..]),
                            None => t,
                        });
                    }
                }
            }
            let command = expand_tilde(&profile.command);
            let argv = if let Some(line) = generic_resume {
                login_shell_argv(&line)
            } else if profile.via_login_shell {
                let mut line = match expand_alias(&profile.command, aliases) {
                    Some(text) => text.to_string(),
                    None => shell_quote(&command),
                };
                for a in &args {
                    line.push(' ');
                    line.push_str(&shell_quote(a));
                }
                login_shell_argv(&line)
            } else {
                let mut v = vec![command];
                v.extend(args);
                v
            };
            LaunchSpec { argv, env, cwd, agent_session_id: agent_id }
        }
    }
}

/// Built-in profiles created on first run when the CLIs are found.
pub fn default_profiles() -> Vec<Profile> {
    let mut out = Vec::new();
    let mut add = |name: &str, icon: &str, kind: AgentKind, command: &str| {
        out.push(Profile {
            id: util::short_id(),
            name: name.into(),
            icon: icon.into(),
            kind,
            command: command.into(),
            args: vec![],
            env: Default::default(),
            via_login_shell: true,
            resume_template: String::new(),
            enabled: true,
            pinned: kind == AgentKind::Claude,
            sort: out_len_hint(kind),
        });
    };
    add("Claude", "claude", AgentKind::Claude, "claude");
    add("Codex", "codex", AgentKind::Codex, "codex");
    out
}

fn out_len_hint(kind: AgentKind) -> i64 {
    match kind {
        AgentKind::Claude => 0,
        AgentKind::Codex => 1,
        AgentKind::Generic => 2,
    }
}

/// Known agent CLIs we offer to add from the Agents settings page.
pub const KNOWN_AGENTS: &[(&str, &str, AgentKind)] = &[
    ("claude", "claude", AgentKind::Claude),
    ("codex", "codex", AgentKind::Codex),
    ("gemini", "gemini", AgentKind::Generic),
    ("amp", "amp", AgentKind::Generic),
    ("opencode", "opencode", AgentKind::Generic),
    ("cursor-agent", "cursor", AgentKind::Generic),
    ("kiro-cli", "kiro", AgentKind::Generic),
    ("agy", "antigravity", AgentKind::Generic),
    ("copilot", "copilot", AgentKind::Generic),
];

/// Runs `cmd` in the user's interactive login shell (no TTY) and returns stdout.
/// Bounded: rc files that hang must not block the daemon.
fn shell_output(cmd: &str) -> Option<String> {
    use std::io::Read;
    let mut child = std::process::Command::new(util::user_shell())
        .args(["-l", "-i", "-c", cmd])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    // Read on a thread: a background process started by an rc file may keep the
    // pipe open after the shell exits, so never block on EOF.
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 8192];
        loop {
            match stdout.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    buf.extend_from_slice(&chunk[..n]);
                    let _ = tx.send(buf.clone());
                }
            }
        }
        let _ = tx.send(buf);
    });
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if std::time::Instant::now() < deadline => std::thread::sleep(std::time::Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    // Take the latest snapshot of output; give the pipe a moment to flush.
    let mut latest = Vec::new();
    let until = std::time::Instant::now() + std::time::Duration::from_millis(500);
    while let Ok(b) = rx.recv_timeout(until.saturating_duration_since(std::time::Instant::now())) {
        latest = b;
    }
    Some(String::from_utf8_lossy(&latest).into_owned())
}

/// Aliases defined in the user's interactive login shell (`name -> value`).
pub fn login_aliases() -> Vec<(String, String)> {
    let Some(out) = shell_output("alias") else {
        return vec![];
    };
    out
        .lines()
        .filter_map(|l| {
            let l = l.strip_prefix("alias ").unwrap_or(l);
            let (k, v) = l.split_once('=')?;
            let v = v.trim().trim_matches('\'').trim_matches('"').to_string();
            Some((k.trim().to_string(), v))
        })
        .collect()
}

/// Which agent an alias launches, if any (e.g. `claude-work='CLAUDE_CONFIG_DIR=… claude'`).
pub fn alias_agent(value: &str) -> Option<(AgentKind, &'static str)> {
    let words: Vec<&str> = value.split_whitespace().filter(|w| !w.contains('=')).collect();
    let cmd = words.first()?.rsplit('/').next()?;
    match cmd {
        "claude" => Some((AgentKind::Claude, "claude")),
        "codex" => Some((AgentKind::Codex, "codex")),
        "gemini" => Some((AgentKind::Generic, "gemini")),
        "amp" | "opencode" | "cursor-agent" | "kiro-cli" | "agy" | "copilot" => Some((AgentKind::Generic, "agent")),
        _ => None,
    }
}

/// PATH as seen by the user's login shell (launchd gives daemons a minimal PATH).
pub fn login_shell_path() -> Option<String> {
    let s = shell_output("printf '__ADE_PATH__%s__END__' \"$PATH\"")?;
    let start = s.find("__ADE_PATH__")? + "__ADE_PATH__".len();
    let end = s[start..].find("__END__")? + start;
    Some(s[start..end].to_string())
}

pub fn which(cmd: &str, path: &str) -> Option<PathBuf> {
    if cmd.contains('/') {
        let p = PathBuf::from(expand_tilde(cmd));
        return p.is_file().then_some(p);
    }
    path.split(':').map(|d| Path::new(d).join(cmd)).find(|p| p.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_claude_session_flags() {
        let args: Vec<String> =
            ["--model", "opus", "--resume", "abc", "-c", "--session-id=x", "--dangerously-skip-permissions"].iter().map(|s| s.to_string()).collect();
        assert_eq!(strip_session_flags(&args, AgentKind::Claude), vec!["--model", "opus", "--dangerously-skip-permissions"]);
        assert_eq!(strip_session_flags(&args, AgentKind::Generic), args);
    }

    #[test]
    fn alias_expansion_in_launch_line() {
        let aliases = vec![("claude-work".to_string(), "CLAUDE_CONFIG_DIR=~/.claude-work claude".to_string())];
        assert_eq!(expand_alias("claude-work", &aliases), Some("CLAUDE_CONFIG_DIR=~/.claude-work claude"));
        assert_eq!(expand_alias("claude", &aliases), None);
        assert_eq!(expand_alias("/bin/claude-work", &aliases), None);
    }

    #[test]
    fn alias_detection() {
        assert_eq!(alias_agent("CLAUDE_CONFIG_DIR=~/.claude-work claude").map(|a| a.0), Some(AgentKind::Claude));
        assert_eq!(alias_agent("/opt/homebrew/bin/codex --full-auto").map(|a| a.0), Some(AgentKind::Codex));
        assert_eq!(alias_agent("ls -la"), None);
    }

    #[test]
    fn transcript_lookup() {
        let dir = std::env::temp_dir().join(format!("ade-test-{}", util::short_id()));
        std::fs::create_dir_all(dir.join("projects/-Users-x-proj")).unwrap();
        std::fs::write(dir.join("projects/-Users-x-proj/1234.jsonl"), "{}").unwrap();
        assert!(claude_transcript_exists(&dir, "1234"));
        assert!(!claude_transcript_exists(&dir, "5678"));
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[cfg(test)]
mod usage_tests {
    use super::*;

    #[test]
    fn codex_rate_limits_from_newest_rollout() {
        let home = std::env::temp_dir().join(format!("adecodex-{}", std::process::id()));
        let dir = home.join("sessions/2026/11/02");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("rollout-x.jsonl"),
            concat!(
                "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/tmp\"}}\n",
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":10.0,\"window_minutes\":300,\"resets_at\":1},\"secondary\":null}}}\n",
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":12.5,\"window_minutes\":300,\"resets_at\":1900000000},\"secondary\":{\"used_percent\":40.0,\"window_minutes\":10080,\"resets_at\":1900500000}}}}\n"
            ),
        )
        .unwrap();
        let mut p = default_profiles().into_iter().find(|p| p.kind == AgentKind::Codex).unwrap();
        p.env.insert("CODEX_HOME".into(), home.to_string_lossy().into_owned());
        let r = codex_rate_limits(&p);
        assert_eq!(r, vec![("five_hour".to_string(), 12.5, Some(1900000000)), ("seven_day".to_string(), 40.0, Some(1900500000))]);
        let _ = std::fs::remove_dir_all(&home);
    }
}
