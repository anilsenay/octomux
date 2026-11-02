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
    let doc = serde_json::json!({ "hooks": hooks });
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

fn login_shell_argv(cmdline: &str) -> Vec<String> {
    vec![util::user_shell(), "-l".into(), "-i".into(), "-c".into(), cmdline.to_string()]
}

pub fn build_launch(paths: &Paths, session: &Session, profile: Option<&Profile>, restoring: bool) -> LaunchSpec {
    let cwd = session.cwd.clone();
    let mut env = vec![("ADE_HOME".to_string(), paths.home.to_string_lossy().into_owned())];
    match session.kind {
        SessionKind::Terminal => LaunchSpec { argv: vec![], env, cwd, agent_session_id: None },
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
                    let cfg = claude_config_dir(profile);
                    if claude_transcript_exists(&cfg, &id) {
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
                        generic_resume = Some(profile.resume_template.replace("{id}", agent_id.as_deref().unwrap_or("")));
                    }
                }
            }
            let command = expand_tilde(&profile.command);
            let argv = if let Some(line) = generic_resume {
                login_shell_argv(&line)
            } else if profile.via_login_shell {
                let mut line = shell_quote(&command);
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
    add("claude", "claude", AgentKind::Claude, "claude");
    add("codex", "codex", AgentKind::Codex, "codex");
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

/// PATH as seen by the user's login shell (launchd gives daemons a minimal PATH).
pub fn login_shell_path() -> Option<String> {
    let out = std::process::Command::new(util::user_shell())
        .args(["-l", "-i", "-c", "printf '__ADE_PATH__%s__END__' \"$PATH\""])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    let s = String::from_utf8_lossy(&out.stdout);
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
    fn transcript_lookup() {
        let dir = std::env::temp_dir().join(format!("ade-test-{}", util::short_id()));
        std::fs::create_dir_all(dir.join("projects/-Users-x-proj")).unwrap();
        std::fs::write(dir.join("projects/-Users-x-proj/1234.jsonl"), "{}").unwrap();
        assert!(claude_transcript_exists(&dir, "1234"));
        assert!(!claude_transcript_exists(&dir, "5678"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
