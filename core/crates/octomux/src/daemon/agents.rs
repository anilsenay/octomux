//! How sessions are launched: shells, agents (Claude/Codex/generic), actions,
//! resume logic and the hook settings injected into Claude.

use crate::util::{self, expand_tilde, shell_quote};
use octomux_proto::Paths;
use octomux_proto::control::{AgentKind, Profile, Session, SessionKind};
use std::path::{Path, PathBuf};

pub struct LaunchSpec {
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: String,
    /// Agent session id to record (Claude ids are assigned up front).
    pub agent_session_id: Option<String>,
}

pub const HOOK_EVENTS: &[&str] =
    &["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification", "SessionEnd", "PermissionRequest"];

pub fn hooks_settings_path(paths: &Paths) -> PathBuf {
    paths.agent_dir().join("claude-settings.json")
}

/// Only the status line: for config dirs that have the integration installed (hooks come from there).
pub fn statusline_only_settings_path(paths: &Paths) -> PathBuf {
    paths.agent_dir().join("claude-settings-statusline.json")
}

/// The Claude config dir a profile uses: its `CLAUDE_CONFIG_DIR` (env, the command line, or the alias the
/// command names, e.g. `claude-work` = `CLAUDE_CONFIG_DIR=~/.claude-work claude`), else `~/.claude`.
pub fn claude_config_dir_resolved(profile: &Profile, aliases: &[(String, String)]) -> PathBuf {
    if let Some(d) = profile.env.get("CLAUDE_CONFIG_DIR") {
        return PathBuf::from(expand_tilde(d));
    }
    let first = profile.command.split_whitespace().next().unwrap_or("");
    let expansion = aliases.iter().find(|(n, _)| n == first).map(|(_, v)| v.as_str()).unwrap_or("");
    for w in profile.command.split_whitespace().chain(expansion.split_whitespace()) {
        if let Some(d) = w.strip_prefix("CLAUDE_CONFIG_DIR=") {
            return PathBuf::from(expand_tilde(d.trim_matches(['"', '\''])));
        }
    }
    util::home_dir().join(".claude")
}

/// Same hooks, without the status line (profiles with `statusline: false`).
pub fn hooks_only_settings_path(paths: &Paths) -> PathBuf {
    paths.agent_dir().join("claude-settings-hooks-only.json")
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
        if matches!(*ev, "PreToolUse" | "PostToolUse" | "PermissionRequest") {
            entry["matcher"] = serde_json::json!("*");
        }
        hooks.insert(ev.to_string(), serde_json::json!([entry]));
    }
    let statusline = format!("{} statusline", shell_quote(&exe));
    let hooks_only = serde_json::json!({ "hooks": hooks });
    std::fs::write(hooks_only_settings_path(paths), serde_json::to_vec_pretty(&hooks_only)?)?;
    let statusline = serde_json::json!({ "type": "command", "command": statusline, "padding": 0 });
    let doc = serde_json::json!({ "hooks": hooks, "statusLine": statusline });
    std::fs::write(hooks_settings_path(paths), serde_json::to_vec_pretty(&doc)?)?;
    std::fs::write(statusline_only_settings_path(paths), serde_json::to_vec_pretty(&serde_json::json!({ "statusLine": statusline }))?)?;
    super::integration::write_script(paths, &exe)?;
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
/// `running`: rollout files of this profile's running sessions; the newest of them is read first, so a
/// reading comes from this profile's own conversations even when another Codex wrote more recently.
pub fn codex_rate_limits(profile: &Profile, running: &[String]) -> Vec<(String, f64, Option<i64>)> {
    let mtime = |p: &str| std::fs::metadata(p).and_then(|m| m.modified()).ok();
    let mut own: Vec<&String> = running.iter().filter(|p| mtime(p).is_some()).collect();
    own.sort_by_key(|p| std::cmp::Reverse(mtime(p)));
    for p in own {
        let r = rate_limits_in(Path::new(p));
        if !r.is_empty() {
            return r;
        }
    }
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
    rate_limits_in(&path)
}

/// The last `rate_limits` record in a rollout file (its last 512 KB).
fn rate_limits_in(path: &Path) -> Vec<(String, f64, Option<i64>)> {
    let Ok(bytes) = std::fs::read(path) else { return vec![] };
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

/// A Codex conversation as its rollout file names it: `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexConversation {
    pub id: String,
    pub path: String,
    pub codex_home: PathBuf,
}

pub fn parse_rollout_path(p: &str) -> Option<CodexConversation> {
    let path = Path::new(p);
    let stem = path.file_name()?.to_str()?.strip_prefix("rollout-")?.strip_suffix(".jsonl")?;
    let id = stem.get(stem.len().checked_sub(36)?..)?;
    uuid::Uuid::parse_str(id).ok()?;
    // file, DD, MM, YYYY, sessions, CODEX_HOME
    let sessions = path.ancestors().nth(4)?;
    if sessions.file_name()? != "sessions" {
        return None;
    }
    Some(CodexConversation { id: id.to_string(), path: p.to_string(), codex_home: sessions.parent()?.to_path_buf() })
}

/// The conversation a running codex works on: the rollout file it keeps open. Exact (like Claude's own
/// `sessions/<pid>.json`): two codex in the same folder never get each other's conversation. None until
/// Codex has created the file (it does so at start, or with the first message).
pub fn codex_conversation_of(pid: i32) -> Option<CodexConversation> {
    crate::procs::open_files(pid).iter().find_map(|p| parse_rollout_path(p))
}

/// Conversation names from `<CODEX_HOME>/session_index.jsonl` (`/rename`, or the name Codex picks after the
/// first turn): one line per change, so the last line for an id wins.
pub fn parse_session_index(text: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    for line in text.lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
        let (Some(id), Some(name)) = (v.get("id").and_then(|x| x.as_str()), v.get("thread_name").and_then(|x| x.as_str())) else { continue };
        if name.trim().is_empty() {
            out.remove(id);
        } else {
            out.insert(id.to_string(), name.trim().to_string());
        }
    }
    out
}

/// What the newest turn event in a Codex rollout chunk says, for a Codex too old to report its state
/// (OSC 7501 came with 0.164): a turn started, finished, or was interrupted (Esc). Waiting for an approval
/// is never written to the rollout, so that state needs a Codex that reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexTurn {
    Started,
    Complete,
    Aborted,
}

/// The event and its time (ms).
pub fn codex_last_turn_event(chunk: &str) -> Option<(CodexTurn, Option<u64>)> {
    let mut last = None;
    for line in chunk.lines() {
        if !line.contains("\"event_msg\"") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
        let turn = match v.pointer("/payload/type").and_then(|t| t.as_str()) {
            Some("task_started" | "turn_started") => CodexTurn::Started,
            Some("task_complete" | "turn_complete") => CodexTurn::Complete,
            Some("turn_aborted") => CodexTurn::Aborted,
            _ => continue,
        };
        last = Some((turn, v.get("timestamp").and_then(|t| t.as_str()).and_then(util::parse_iso_millis)));
    }
    last
}

/// `codex --version` as the profile runs Codex (alias, login shell): "0.166.0".
pub fn codex_version(profile: &Profile, aliases: &[(String, String)]) -> Option<String> {
    let line = match expand_alias(&profile.command, aliases) {
        Some(text) => format!("{text} --version"),
        None => format!("{} --version", shell_quote(&expand_tilde(&profile.command))),
    };
    let env: String = profile.env.iter().map(|(k, v)| format!("{k}={} ", shell_quote(&expand_tilde(v)))).collect();
    let out = shell_output(&format!("{env}{line}"))?;
    out.split_whitespace().find(|w| w.chars().next().is_some_and(|c| c.is_ascii_digit()) && w.contains('.')).map(str::to_string)
}

/// Codex reports its own state (OSC 7501, with blocked and done) from 0.164 on.
pub fn codex_reports_status(version: &str) -> bool {
    let mut it = version.split(['.', '-']).map(|p| p.parse::<u64>().unwrap_or(0));
    let (major, minor) = (it.next().unwrap_or(0), it.next().unwrap_or(0));
    major > 0 || minor >= 164
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
    build_launch_with_prompt(paths, session, profile, restoring, aliases, None)
}

/// Like `build_launch`; `prompt` (a new session's first message, from the chat start screen) is passed
/// as the CLI's positional prompt, so it is never typed before the agent is ready.
pub fn build_launch_with_prompt(paths: &Paths, session: &Session, profile: Option<&Profile>, restoring: bool, aliases: &[(String, String)], prompt: Option<&str>) -> LaunchSpec {
    let cwd = session.cwd.clone();
    let mut env = vec![(octomux_proto::HOME_VAR.to_string(), paths.home.to_string_lossy().into_owned())];
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
            // Flags picked when the session was started (model, effort, permission mode, images), before any
            // subcommand (`codex resume`); never one of the session flags managed here.
            args.extend(strip_session_flags(&session.extra_args, profile.kind));
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
                    // With the integration installed in this config dir the hooks already come from there;
                    // passing them again would report every event twice.
                    let integrated = super::integration::status(&claude_config_dir_resolved(profile, aliases), &super::integration::script_path(paths))
                        == super::integration::Status::Installed;
                    let settings = match (integrated, profile.statusline) {
                        (true, true) => Some(statusline_only_settings_path(paths)),
                        (true, false) => None,
                        (false, true) => Some(hooks_settings_path(paths)),
                        (false, false) => Some(hooks_only_settings_path(paths)),
                    };
                    if let Some(settings) = settings {
                        args.extend(["--settings".into(), settings.to_string_lossy().into_owned()]);
                    }
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
            if let Some(p) = prompt.filter(|p| !restoring && !p.trim().is_empty()) {
                if matches!(profile.kind, AgentKind::Claude | AgentKind::Codex) {
                    args.push(p.to_string());
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
            statusline: true,
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
    fn launch_skips_our_hooks_when_the_integration_is_installed() {
        let tmp = std::env::temp_dir().join(format!("octomux-launch-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        let paths = Paths { home: tmp.join("home") };
        util::ensure_dir_0700(&paths.home).unwrap();
        write_hook_settings(&paths).unwrap();
        let cfg = tmp.join("cfg");
        let mut p = default_profiles().into_iter().find(|p| p.kind == AgentKind::Claude).unwrap();
        p.env.insert("CLAUDE_CONFIG_DIR".into(), cfg.to_string_lossy().into_owned());
        let session: Session = serde_json::from_value(serde_json::json!({
            "id": "s1", "project_id": "p1", "kind": "agent", "profile_id": p.id, "title": "", "custom_title": "",
            "cwd": "/tmp", "state": "running", "activity": "idle", "unread": false, "agent_session_id": null,
            "created_at": 0, "last_activity_at": 0, "exit_code": null, "placement": "tab"
        }))
        .unwrap();
        let line = |p: &Profile| build_launch(&paths, &session, Some(p), false, &[]).argv.join(" ");
        let hooks = hooks_settings_path(&paths).to_string_lossy().into_owned();
        let only_status = statusline_only_settings_path(&paths).to_string_lossy().into_owned();
        let l = line(&p);
        assert!(l.contains(&hooks) && !l.contains(&only_status), "{l}");
        super::super::integration::install(&cfg, &super::super::integration::script_path(&paths)).unwrap();
        let l = line(&p);
        assert!(l.contains(&only_status) && !l.contains(&hooks), "{l}");
        p.statusline = false;
        let l = line(&p);
        assert!(!l.contains("--settings"), "{l}");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn config_dir_of_a_profile() {
        let mut p = default_profiles().into_iter().find(|p| p.kind == AgentKind::Claude).unwrap();
        let home = util::home_dir();
        let aliases = vec![("claude-work".to_string(), "CLAUDE_CONFIG_DIR=~/.claude-work claude".to_string())];
        assert_eq!(claude_config_dir_resolved(&p, &aliases), home.join(".claude"));
        p.command = "claude-work".into();
        assert_eq!(claude_config_dir_resolved(&p, &aliases), home.join(".claude-work"));
        p.command = "CLAUDE_CONFIG_DIR=/tmp/c claude".into();
        assert_eq!(claude_config_dir_resolved(&p, &aliases), PathBuf::from("/tmp/c"));
        p.env.insert("CLAUDE_CONFIG_DIR".into(), "/tmp/env".into());
        assert_eq!(claude_config_dir_resolved(&p, &aliases), PathBuf::from("/tmp/env"));
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
mod codex_tests {
    use super::*;

    #[test]
    fn rollout_paths() {
        let p = "/Users/x/.codex/sessions/2026/11/04/rollout-2026-11-04T10-24-41-01a1a572-1cdc-7503-b70c-b49d5c827750.jsonl";
        let c = parse_rollout_path(p).unwrap();
        assert_eq!(c.id, "01a1a572-1cdc-7503-b70c-b49d5c827750");
        assert_eq!(c.codex_home, PathBuf::from("/Users/x/.codex"));
        assert_eq!(c.path, p);
        assert_eq!(parse_rollout_path("/Users/x/.codex/sessions/2026/11/04/notes.jsonl"), None);
        assert_eq!(parse_rollout_path("/Users/x/.codex/archive/2026/11/04/rollout-2026-11-04T10-24-41-01a1a572-1cdc-7503-b70c-b49d5c827750.jsonl"), None);
        assert_eq!(parse_rollout_path("/tmp/rollout-x.jsonl"), None);
    }

    #[test]
    fn conversation_names_last_entry_wins() {
        let text = concat!(
            "{\"id\":\"a\",\"thread_name\":\"First\",\"updated_at\":\"x\"}\n",
            "{\"id\":\"b\",\"thread_name\":\"Other\"}\n",
            "not json\n",
            "{\"id\":\"a\",\"thread_name\":\" Renamed \"}\n"
        );
        let m = parse_session_index(text);
        assert_eq!(m.get("a").map(String::as_str), Some("Renamed"));
        assert_eq!(m.get("b").map(String::as_str), Some("Other"));
    }

    #[test]
    fn turn_events() {
        let chunk = concat!(
            "{\"timestamp\":\"2026-11-04T07:24:46.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\"}}\n",
            "{\"timestamp\":\"2026-11-04T07:25:08.678Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"reason\":\"interrupted\"}}\n",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n"
        );
        let (turn, ts) = codex_last_turn_event(chunk).unwrap();
        assert_eq!(turn, CodexTurn::Aborted);
        assert_eq!(ts, util::parse_iso_millis("2026-11-04T07:25:08.678Z"));
        assert_eq!(codex_last_turn_event("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}").map(|t| t.0), Some(CodexTurn::Complete));
        assert_eq!(codex_last_turn_event("{\"type\":\"response_item\"}"), None);
    }

    #[test]
    fn versions_that_report() {
        assert!(codex_reports_status("0.166.0"));
        assert!(codex_reports_status("0.164.0"));
        assert!(codex_reports_status("0.168.0-alpha.1"));
        assert!(codex_reports_status("1.0.0"));
        assert!(!codex_reports_status("0.163.2"));
        assert!(!codex_reports_status("0.144.4"));
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
        let r = codex_rate_limits(&p, &[]);
        assert_eq!(r, vec![("five_hour".to_string(), 12.5, Some(1900000000)), ("seven_day".to_string(), 40.0, Some(1900500000))]);
        let _ = std::fs::remove_dir_all(&home);
    }
}

// MARK: Claude usage via its own `/usage` command

/// `claude -p /usage`: a local command (no model call, no tokens), as the profile would run Claude
/// (its args, aliases, login shell). `--no-session-persistence` keeps it out of the resume list.
pub fn claude_usage_argv(profile: &Profile, aliases: &[(String, String)]) -> Vec<String> {
    let mut args = strip_session_flags(&profile.args, profile.kind);
    args.extend(["-p", "/usage", "--output-format", "json", "--no-session-persistence"].map(String::from));
    let command = expand_tilde(&profile.command);
    if profile.via_login_shell {
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
    }
}

/// Reads `/usage` output: "Current session: 8% used · resets Nov 3 at 2:30am (Europe/Istanbul)",
/// "Current week (all models): 6% used · resets Nov 9 at 2pm (…)", "Current week (Fable): 0% used …".
/// Returns (window, percent, resets_at) with the same window names the status line uses.
pub fn parse_claude_usage(text: &str, now: i64) -> Vec<(String, f64, Option<i64>)> {
    let mut out = Vec::new();
    for line in text.lines() {
        let l = line.trim();
        let Some(rest) = l.strip_prefix("Current ") else { continue };
        let Some((label, tail)) = rest.split_once(':') else { continue };
        let window = if label.trim() == "session" {
            "five_hour".to_string()
        } else if let Some(inner) = label.trim().strip_prefix("week") {
            let inner = inner.trim().trim_start_matches('(').trim_end_matches(')').trim().to_lowercase();
            if inner.is_empty() || inner == "all models" { "seven_day".to_string() } else { format!("seven_day_{}", inner.replace(' ', "_")) }
        } else {
            continue;
        };
        let tail = tail.trim();
        let Some(pct_end) = tail.find('%') else { continue };
        let Ok(pct) = tail[..pct_end].trim().parse::<f64>() else { continue };
        let resets = tail.split_once("resets").map(|(_, r)| r.trim()).and_then(|r| parse_reset_time(r, now));
        out.push((window, pct, resets));
    }
    out
}

/// "Nov 3 at 2:30am (Europe/Istanbul)", "Nov 9 at 2pm", "2:30am", "Nov 9" in local time → unix time.
/// The zone in parentheses is the machine's own (that is how Claude prints it), so local time is used.
pub fn parse_reset_time(s: &str, now: i64) -> Option<i64> {
    let s = s.split('(').next().unwrap_or(s).trim().trim_end_matches(',');
    let (date, time) = match s.split_once(" at ") {
        Some((d, t)) => (Some(d.trim()), Some(t.trim())),
        None if s.chars().next().is_some_and(|c| c.is_ascii_digit()) => (None, Some(s)),
        None => (Some(s), None),
    };
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let t = now as libc::time_t;
    unsafe { libc::localtime_r(&t, &mut tm) };
    if let Some(d) = date {
        let mut parts = d.split_whitespace();
        let mon = parts.next()?;
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
        let m = months.iter().position(|x| mon.to_lowercase().starts_with(x))? as i32;
        let day: i32 = parts.next()?.trim_end_matches(',').parse().ok()?;
        if let Some(y) = parts.next().and_then(|y| y.parse::<i32>().ok()) {
            tm.tm_year = y - 1900;
        }
        tm.tm_mon = m;
        tm.tm_mday = day;
    }
    let (mut hour, mut min) = (0, 0);
    if let Some(t) = time {
        let t = t.to_lowercase();
        let pm = t.ends_with("pm");
        let am = t.ends_with("am");
        let digits = t.trim_end_matches("am").trim_end_matches("pm").trim();
        let (h, m) = match digits.split_once(':') {
            Some((h, m)) => (h.parse::<i32>().ok()?, m.parse::<i32>().ok()?),
            None => (digits.parse::<i32>().ok()?, 0),
        };
        hour = if pm && h < 12 { h + 12 } else if am && h == 12 { 0 } else { h };
        min = m;
    }
    tm.tm_hour = hour;
    tm.tm_min = min;
    tm.tm_sec = 0;
    tm.tm_isdst = -1;
    let mut at = unsafe { libc::mktime(&mut tm) } as i64;
    if at < 0 {
        return None;
    }
    // "Jan 2" printed in late December is next year; a bare time already past is tomorrow.
    if date.is_some() && at < now - 86_400 {
        tm.tm_year += 1;
        tm.tm_isdst = -1;
        at = unsafe { libc::mktime(&mut tm) } as i64;
    } else if date.is_none() && at < now {
        at += 86_400;
    }
    Some(at)
}

#[cfg(test)]
mod claude_usage_tests {
    use super::*;

    #[test]
    fn parses_usage_command_output() {
        let now = parse_reset_time("Nov 2 at 11pm", 1_793_600_000).unwrap();
        let text = "You are currently using your subscription\n\nCurrent session: 8% used · resets Nov 3 at 2:30am (Europe/Istanbul)\nCurrent week (all models): 6% used · resets Nov 9 at 2pm (Europe/Istanbul)\nCurrent week (Fable): 0% used · resets Nov 9 at 2pm (Europe/Istanbul)\n\nLast 24h · 1830 requests\n  91%  Start fresh";
        let r = parse_claude_usage(text, now);
        assert_eq!(r.len(), 3, "{r:?}");
        assert_eq!((r[0].0.as_str(), r[0].1), ("five_hour", 8.0));
        assert_eq!((r[1].0.as_str(), r[1].1), ("seven_day", 6.0));
        assert_eq!(r[2].0, "seven_day_fable");
        // 3:30 hours after "Nov 2 at 11pm", and the week resets 6 days 15 hours later.
        assert_eq!(r[0].2.unwrap() - now, 3 * 3600 + 1800);
        assert_eq!(r[1].2.unwrap() - now, 6 * 86_400 + 15 * 3600);
        assert_eq!(parse_reset_time("12am", now).unwrap() - now, 3600);
    }
}
