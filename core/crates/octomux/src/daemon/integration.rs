//! Optional Claude Code integration: our hooks in a Claude config dir's own `settings.json`, so a `claude`
//! typed in an Octomux terminal tab reports to that tab (sessions we launch get them via `--settings`).
//! The hook script does nothing outside an Octomux tab. Only entries that run our script are ever added or
//! removed; everything else in the file stays as it is (key order too), and a backup is kept.

use super::agents::HOOK_EVENTS;
use crate::util::shell_quote;
use anyhow::{Context, Result, bail};
use octomux_proto::Paths;
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};

/// Bumped when the hook entries change; older installs show as outdated.
pub const VERSION: u32 = 1;

pub fn script_path(paths: &Paths) -> PathBuf {
    paths.agent_dir().join("claude-hook.sh")
}

/// The script the installed hooks run: a no-op outside an Octomux tab, else our `hook` command.
pub fn write_script(paths: &Paths, exe: &str) -> Result<()> {
    let body = format!(
        "#!/bin/sh\n# Octomux Claude Code integration v{VERSION}. Inert outside an Octomux terminal tab.\n\
         [ -n \"$OCTOMUX_SESSION_ID\" ] || exit 0\nexec {} hook \"$1\"\n",
        shell_quote(exe)
    );
    let p = script_path(paths);
    if std::fs::read_to_string(&p).ok().as_deref() != Some(&body) {
        std::fs::write(&p, &body)?;
    }
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755))?;
    Ok(())
}

fn command_for(script: &Path, event: &str) -> String {
    format!("{} {event}", shell_quote(&script.to_string_lossy()))
}

fn is_ours(hook: &Value, script: &Path) -> bool {
    hook.get("command").and_then(|c| c.as_str()).is_some_and(|c| c.contains(&*script.to_string_lossy()))
}

#[derive(Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Installed,
    /// Some events are missing (an older Octomux, or edited by hand).
    Outdated,
    Missing,
}

pub fn settings_file(config_dir: &Path) -> PathBuf {
    config_dir.join("settings.json")
}

fn read(file: &Path) -> Result<Value> {
    match std::fs::read_to_string(file) {
        Ok(t) if t.trim().is_empty() => Ok(json!({})),
        Ok(t) => {
            let v: Value = serde_json::from_str(&t).with_context(|| format!("{} is not valid JSON; not touching it", file.display()))?;
            if !v.is_object() {
                bail!("{} is not a JSON object; not touching it", file.display());
            }
            Ok(v)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        Err(e) => Err(e).with_context(|| format!("read {}", file.display())),
    }
}

pub fn status(config_dir: &Path, script: &Path) -> Status {
    let Ok(v) = read(&settings_file(config_dir)) else { return Status::Missing };
    let have = |ev: &str| {
        v.pointer(&format!("/hooks/{ev}"))
            .and_then(|a| a.as_array())
            .is_some_and(|a| a.iter().any(|e| e.get("hooks").and_then(|h| h.as_array()).is_some_and(|h| h.iter().any(|x| is_ours(x, script)))))
    };
    match HOOK_EVENTS.iter().filter(|e| have(e)).count() {
        0 => Status::Missing,
        n if n == HOOK_EVENTS.len() => Status::Installed,
        _ => Status::Outdated,
    }
}

/// Removes our hook entries (and groups/events left empty by that); true if anything changed.
fn strip(v: &mut Value, script: &Path) -> bool {
    let Some(hooks) = v.get_mut("hooks").and_then(|h| h.as_object_mut()) else { return false };
    let mut changed = false;
    for groups in hooks.values_mut() {
        let Some(groups) = groups.as_array_mut() else { continue };
        for g in groups.iter_mut() {
            if let Some(list) = g.get_mut("hooks").and_then(|h| h.as_array_mut()) {
                let n = list.len();
                list.retain(|x| !is_ours(x, script));
                changed |= list.len() != n;
            }
        }
        groups.retain(|g| g.get("hooks").and_then(|h| h.as_array()).is_none_or(|h| !h.is_empty()));
    }
    hooks.retain(|_, g| g.as_array().is_none_or(|a| !a.is_empty()));
    if hooks.is_empty() {
        v.as_object_mut().unwrap().remove("hooks");
    }
    changed
}

/// Adds our entries for every event (replacing older ones of ours). Returns the backup written, if any.
pub fn install(config_dir: &Path, script: &Path) -> Result<Option<PathBuf>> {
    let file = settings_file(config_dir);
    let mut v = read(&file)?;
    strip(&mut v, script);
    let obj = v.as_object_mut().unwrap();
    let hooks = obj.entry("hooks").or_insert_with(|| Value::Object(Map::new()));
    let Some(hooks) = hooks.as_object_mut() else { bail!("\"hooks\" in {} is not an object; not touching it", file.display()) };
    for ev in HOOK_EVENTS {
        let mut entry = json!({ "hooks": [{ "type": "command", "command": command_for(script, ev), "timeout": 5 }] });
        if matches!(*ev, "PreToolUse" | "PostToolUse" | "PermissionRequest") {
            entry["matcher"] = json!("*");
        }
        let groups = hooks.entry(ev.to_string()).or_insert_with(|| json!([]));
        let Some(groups) = groups.as_array_mut() else { bail!("hooks.{ev} in {} is not a list; not touching it", file.display()) };
        groups.push(entry);
    }
    write(&file, &v)
}

pub fn uninstall(config_dir: &Path, script: &Path) -> Result<Option<PathBuf>> {
    let file = settings_file(config_dir);
    let mut v = read(&file)?;
    if !strip(&mut v, script) {
        return Ok(None);
    }
    write(&file, &v)
}

/// Backup of the previous file next to it, then an atomic replace keeping its permissions.
fn write(file: &Path, v: &Value) -> Result<Option<PathBuf>> {
    let dir = file.parent().context("settings file has no folder")?;
    std::fs::create_dir_all(dir)?;
    let backup = if file.exists() {
        let b = file.with_extension("json.octomux-backup");
        std::fs::copy(file, &b)?;
        Some(b)
    } else {
        None
    };
    let tmp = dir.join(format!(".settings.json.octomux-{}", std::process::id()));
    std::fs::write(&tmp, serde_json::to_string_pretty(v)? + "\n")?;
    if let Ok(m) = std::fs::metadata(file) {
        std::fs::set_permissions(&tmp, m.permissions())?;
    }
    std::fs::rename(&tmp, file)?;
    Ok(backup)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("octomux-integ-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }
    const SCRIPT: &str = "/Users/x/Library/Application Support/Octomux/agent/claude-hook.sh";

    #[test]
    fn install_keeps_everything_else_and_uninstall_restores_it() {
        let d = dir("keep");
        let original = r#"{
  "model": "opus",
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "say done" }] }],
    "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "guard.sh" }] }]
  },
  "permissions": { "allow": ["Bash(ls)"] },
  "statusLine": { "type": "command", "command": "x" }
}"#;
        std::fs::write(settings_file(&d), original).unwrap();
        let script = Path::new(SCRIPT);
        assert_eq!(status(&d, script), Status::Missing);
        let backup = install(&d, script).unwrap().unwrap();
        assert_eq!(std::fs::read_to_string(&backup).unwrap(), original);
        assert_eq!(status(&d, script), Status::Installed);
        let v: Value = serde_json::from_str(&std::fs::read_to_string(settings_file(&d)).unwrap()).unwrap();
        // Key order kept; the user's hooks stay first in each event.
        assert_eq!(v.as_object().unwrap().keys().collect::<Vec<_>>(), ["model", "hooks", "permissions", "statusLine"]);
        assert_eq!(v["hooks"]["Stop"][0]["hooks"][0]["command"], "say done");
        assert_eq!(v["hooks"]["Stop"][1]["hooks"][0]["command"], format!("'{SCRIPT}' Stop"));
        assert_eq!(v["hooks"]["PreToolUse"][0]["matcher"], "Bash");
        assert_eq!(v["hooks"]["PreToolUse"][1]["matcher"], "*");
        // Installing again replaces ours instead of adding a second copy.
        install(&d, script).unwrap();
        let v: Value = serde_json::from_str(&std::fs::read_to_string(settings_file(&d)).unwrap()).unwrap();
        assert_eq!(v["hooks"]["Stop"].as_array().unwrap().len(), 2);
        uninstall(&d, script).unwrap();
        let back: Value = serde_json::from_str(&std::fs::read_to_string(settings_file(&d)).unwrap()).unwrap();
        assert_eq!(back, serde_json::from_str::<Value>(original).unwrap());
        assert_eq!(status(&d, script), Status::Missing);
    }

    #[test]
    fn fresh_config_dir_and_partial_install() {
        let d = dir("fresh");
        let script = Path::new(SCRIPT);
        assert_eq!(install(&d, script).unwrap(), None); // no file before: no backup
        assert_eq!(status(&d, script), Status::Installed);
        let mut v: Value = serde_json::from_str(&std::fs::read_to_string(settings_file(&d)).unwrap()).unwrap();
        v["hooks"].as_object_mut().unwrap().remove("PostToolUse");
        std::fs::write(settings_file(&d), v.to_string()).unwrap();
        assert_eq!(status(&d, script), Status::Outdated);
        uninstall(&d, script).unwrap();
        assert_eq!(std::fs::read_to_string(settings_file(&d)).unwrap().trim(), "{}");
    }

    #[test]
    fn broken_settings_are_left_alone() {
        let d = dir("broken");
        std::fs::write(settings_file(&d), "{ \"model\": ").unwrap();
        assert!(install(&d, Path::new(SCRIPT)).is_err());
        assert_eq!(std::fs::read_to_string(settings_file(&d)).unwrap(), "{ \"model\": ");
        std::fs::write(settings_file(&d), r#"{"hooks": []}"#).unwrap();
        assert!(install(&d, Path::new(SCRIPT)).is_err());
    }
}
