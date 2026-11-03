//! The Octomux daemon: owns the catalog (workspaces, projects, sessions, tabs,
//! profiles, settings), spawns and watches session holders, restores sessions
//! after crashes/reboots, turns hook/OSC signals into activity + notifications,
//! and serves the control API.

pub mod agents;
pub mod integration;
pub mod store;

use crate::holder::HolderClient;
use crate::util;
use octomux_proto::control::*;
use octomux_proto::{Frame, HolderEvent, HolderRequest, Kind, Paths, Role};
use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use store::Store;

pub const PROJECT_COLORS: &[&str] = &["#459CF7", "#F4BF25", "#39C363", "#E45A9F", "#B168D4", "#37BEB4", "#EF8C39", "#EA603E", "#8B949C"];

pub struct Daemon {
    paths: Paths,
    state: Mutex<State>,
    store: Mutex<Store>,
    subs: Mutex<Vec<Sender<String>>>,
    monitored: Mutex<HashSet<String>>,
    spawning: Mutex<HashSet<String>>,
    /// First message for agent sessions about to be spawned (`session.create` `prompt`).
    prompts: Mutex<HashMap<String, String>>,
    claude_usage_running: std::sync::atomic::AtomicBool,
    /// Set when a Claude session finished a turn: the usage loop probes `/usage` shortly after.
    usage_poke: Mutex<Option<(Instant, Vec<String>)>>,
    cmd_started: Mutex<HashMap<String, Instant>>,
    dirty: Sender<()>,
    login_path: Mutex<Option<String>>,
    aliases: Mutex<Vec<(String, String)>>,
    /// Per session: transcript path, bytes already scanned, titles seen so far (custom, ai).
    title_scan: Mutex<HashMap<String, TitleScan>>,
    /// Per session: when its activity last changed (ms), so an interrupt marker older than that is ignored.
    activity_at: Mutex<HashMap<String, u64>>,
    /// Per session: the process of the program reporting its state (OSC 7501), to notice it dying without
    /// its `clear` (killed, crashed). -1 = an app we can't find by name: only its own `clear` counts.
    program_pid: Mutex<HashMap<String, i32>>,
    /// Per session: when find_claude_conversation last ran.
    resume_scan: Mutex<HashMap<String, Instant>>,
}

#[derive(Default)]
struct TitleScan {
    path: String,
    offset: u64,
    custom: Option<String>,
    ai: Option<String>,
}

/// Title records in a Claude transcript chunk: the last `custom-title` (set by /rename) and `ai-title`.
pub(crate) fn scan_titles(chunk: &str, custom: &mut Option<String>, ai: &mut Option<String>) {
    for line in chunk.lines() {
        if !line.contains("-title\"") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        match v.get("type").and_then(|t| t.as_str()) {
            Some("custom-title") => {
                if let Some(t) = v.get("customTitle").and_then(|t| t.as_str()).filter(|t| !t.trim().is_empty()) {
                    *custom = Some(t.trim().to_string());
                }
            }
            Some("ai-title") => {
                if let Some(t) = v.get("aiTitle").and_then(|t| t.as_str()).filter(|t| !t.trim().is_empty()) {
                    *ai = Some(t.trim().to_string());
                }
            }
            _ => {}
        }
    }
}

/// The newest turn record in a Claude transcript chunk: `Some((true, ts))` when it is the marker Claude writes
/// when you press Esc (`[Request interrupted by user]`, `… for tool use]`), `Some((false, ts))` for any other
/// prompt, reply or tool result. Esc runs no hook (Stop is skipped on an interrupt), so this is how we see it.
/// `ts` is the record's time in ms. Subagent (sidechain) and meta records are not turns.
pub(crate) fn last_turn_record(chunk: &str) -> Option<(bool, Option<u64>)> {
    let mut last = None;
    for line in chunk.lines() {
        if !(line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"")) {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        let ty = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
        if !matches!(ty, "user" | "assistant") || v.get("isSidechain").and_then(|b| b.as_bool()) == Some(true) || v.get("isMeta").and_then(|b| b.as_bool()) == Some(true) {
            continue;
        }
        let content = v.pointer("/message/content");
        let texts: Vec<&str> = match content {
            Some(Value::String(t)) => vec![t.as_str()],
            Some(Value::Array(items)) => items.iter().filter_map(|i| i.get("text").and_then(|t| t.as_str())).collect(),
            _ => vec![],
        };
        let interrupted = ty == "user" && texts.iter().any(|t| t.trim_start().starts_with("[Request interrupted by user"));
        let ts = v.get("timestamp").and_then(|t| t.as_str()).and_then(util::parse_iso_millis);
        last = Some((interrupted, ts));
    }
    last
}

/// The `sessionId` in a Claude `sessions/<pid>.json` record, if it belongs to this process: same pid, and
/// started within a minute of the process (`started`, seconds).
pub(crate) fn claude_session_record(text: &str, pid: i32, started: i64) -> Option<String> {
    let v: Value = serde_json::from_str(text).ok()?;
    if v.get("pid")?.as_i64()? != pid as i64 {
        return None;
    }
    let at = v.get("startedAt")?.as_i64()? / 1000;
    if (at - started).abs() > 60 {
        return None;
    }
    v.get("sessionId")?.as_str().filter(|s| !s.is_empty()).map(str::to_string)
}

/// OSC 7501 `app` names of coding agents (others, like build tools, also report but aren't agents).
fn is_agent_app(app: &str) -> bool {
    matches!(app, "claude-code" | "claude" | "codex" | "gemini" | "opencode" | "pi" | "amp" | "cursor-agent" | "copilot" | "kimi" | "kiro" | "grok")
}

/// Display name for an OSC 7501 `app` ("claude-code" → "Claude Code").
fn app_label(app: &str) -> String {
    match app {
        "claude-code" | "claude" => "Claude Code".into(),
        "codex" => "Codex".into(),
        other => other
            .split(['-', '_'])
            .filter(|w| !w.is_empty())
            .map(|w| {
                let mut c = w.chars();
                c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
            })
            .collect::<Vec<_>>()
            .join(" "),
    }
}

pub fn run(paths: Paths) -> Result<()> {
    util::ensure_dir_0700(&paths.home)?;
    util::ensure_dir_0700(&paths.run_dir())?;
    util::ensure_dir_0700(&paths.logs_dir())?;
    let sock = paths.daemon_socket();
    if UnixStream::connect(&sock).is_ok() {
        bail!("daemon already running");
    }

    if !paths.db().exists() && paths.legacy_db().exists() {
        // Pre-rename database: VACUUM INTO writes a consistent copy (WAL included); the old file stays as a backup.
        let old = rusqlite::Connection::open(paths.legacy_db())?;
        old.execute("VACUUM INTO ?1", [paths.db().to_string_lossy()])?;
    }
    let store = Store::open(&paths.db())?;
    let mut state = store.load()?;
    let first_run = state.workspaces.is_empty();
    if first_run {
        state.workspaces.push(Workspace { id: util::short_id(), name: "Personal".into(), color: "#E8704A".into(), sort: 0, icon: None });
        state.profiles = agents::default_profiles();
        store.save_all(&state)?;
    }
    agents::write_hook_settings(&paths)?;

    let (dirty_tx, dirty_rx) = channel();
    let d = Arc::new(Daemon {
        paths: paths.clone(),
        state: Mutex::new(state),
        store: Mutex::new(store),
        subs: Mutex::new(Vec::new()),
        monitored: Mutex::new(HashSet::new()),
        spawning: Mutex::new(HashSet::new()),
        prompts: Mutex::new(HashMap::new()),
        claude_usage_running: std::sync::atomic::AtomicBool::new(false),
        usage_poke: Mutex::new(None),
        cmd_started: Mutex::new(HashMap::new()),
        dirty: dirty_tx,
        login_path: Mutex::new(None),
        aliases: Mutex::new(Vec::new()),
        title_scan: Mutex::new(HashMap::new()),
        activity_at: Mutex::new(HashMap::new()),
        program_pid: Mutex::new(HashMap::new()),
        resume_scan: Mutex::new(HashMap::new()),
    });

    // Bind under a private name, then atomically publish (never unlink a live socket).
    let tmp = paths.run_dir().join(format!("d{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let listener = UnixListener::bind(&tmp).with_context(|| format!("bind {}", tmp.display()))?;
    util::set_mode_0600(&tmp);
    std::fs::rename(&tmp, &sock)?;
    eprintln!("[ade-daemon] pid {} listening on {}", std::process::id(), sock.display());
    // Hook events sent while we were down. One that is older than a state change seen since (a live hook
    // that got here first) is stale and skipped.
    for (ts, id, event, payload) in crate::hook_spool::take(&paths) {
        let since = d.activity_at.lock().unwrap().get(&id).copied().unwrap_or(0);
        if ts >= since {
            d.on_hook(&id, &event, &payload);
        }
    }

    {
        let d = d.clone();
        std::thread::spawn(move || broadcaster(d, dirty_rx));
    }
    {
        // The user's login environment must be known before sessions are restored
        // (after a reboot the daemon starts from launchd with a minimal PATH).
        let d = d.clone();
        std::thread::spawn(move || {
            d.refresh_shell_env();
            d.reconcile();
        });
    }
    {
        let d = d.clone();
        // Claude `/usage` a few seconds after a Claude session finishes a turn, for that session's profile
        // (turns close together share one probe). The periodic refresh comes from the app, which asks
        // only for the profiles its status bar shows (`usage.refresh` with `profile_ids`).
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_secs(3));
            let due = {
                let mut poke = d.usage_poke.lock().unwrap();
                match &*poke {
                    Some((t, _)) if t.elapsed() >= Duration::from_secs(6) => poke.take().map(|(_, ids)| ids),
                    _ => None,
                }
            };
            if let Some(ids) = due {
                d.poll_codex_usage(Some(&ids));
                d.poll_claude_usage(Some(&ids));
            }
        });
    }
    {
        let d = d.clone();
        std::thread::spawn(move || loop {
            // Also notices Esc interrupts (see last_turn_record): kept short so the state follows quickly.
            std::thread::sleep(Duration::from_secs(1));
            d.poll_agent_titles();
            d.check_reporting_programs();
        });
    }

    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let d = d.clone();
        std::thread::spawn(move || {
            let _ = d.serve(stream);
        });
    }
    Ok(())
}

fn broadcaster(d: Arc<Daemon>, rx: Receiver<()>) {
    while rx.recv().is_ok() {
        std::thread::sleep(Duration::from_millis(30));
        while rx.try_recv().is_ok() {}
        let line = {
            let s = d.state.lock().unwrap();
            serde_json::to_string(&json!({ "event": "state", "data": &*s })).unwrap()
        };
        d.subs.lock().unwrap().retain(|tx| tx.send(line.clone()).is_ok());
    }
}

fn holder_alive(paths: &Paths, id: &str) -> bool {
    UnixStream::connect(paths.holder_socket(id)).is_ok()
}

fn strip_title(t: &str) -> String {
    t.trim_start_matches(|c: char| !c.is_alphanumeric() && c != '~' && c != '/' && c != '.' && c != '(').trim().to_string()
}

impl Daemon {
    fn refresh_shell_env(&self) {
        if let Some(p) = agents::login_shell_path() {
            *self.login_path.lock().unwrap() = Some(p);
        }
        *self.aliases.lock().unwrap() = agents::login_aliases();
    }

    fn changed(&self) {
        let _ = self.dirty.send(());
    }

    fn persist_session(&self, s: &Session) {
        let store = self.store.lock().unwrap();
        let _ = store.put("session", &s.id, s);
        // Agent sessions also go to the history (kept after the session is removed, to resume later).
        if s.kind == SessionKind::Agent {
            let _ = store.put_history(s);
        }
    }

    /// Stores a notification (notification center) and tells the clients.
    fn notify(&self, n: Notification) {
        let stored = self.store.lock().unwrap().add_notification(&n);
        match stored {
            Ok(st) => self.emit("notify", serde_json::to_value(st).unwrap()),
            Err(_) => self.emit("notify", serde_json::to_value(n).unwrap()),
        }
    }

    fn notifications_changed(&self) {
        self.emit("notifications_changed", json!({}));
    }

    fn emit(&self, event: &str, data: Value) {
        let line = serde_json::to_string(&json!({ "event": event, "data": data })).unwrap();
        self.subs.lock().unwrap().retain(|tx| tx.send(line.clone()).is_ok());
    }

    fn with_session<R>(&self, id: &str, f: impl FnOnce(&mut Session) -> R) -> Option<R> {
        let mut st = self.state.lock().unwrap();
        let s = st.sessions.iter_mut().find(|s| s.id == id)?;
        let r = f(s);
        let copy = s.clone();
        drop(st);
        self.persist_session(&copy);
        Some(r)
    }

    pub fn setting(&self, key: &str, project_id: Option<&str>) -> Option<Value> {
        let st = self.state.lock().unwrap();
        let mut scopes = Vec::new();
        if let Some(pid) = project_id {
            scopes.push(format!("project:{pid}"));
            if let Some(p) = st.projects.iter().find(|p| p.id == pid) {
                scopes.push(format!("workspace:{}", p.workspace_id));
            }
        }
        scopes.push("global".into());
        for sc in scopes {
            if let Some(s) = st.settings.iter().find(|s| s.scope == sc && s.key == key) {
                return Some(s.value.clone());
            }
        }
        None
    }

    /// Startup: re-attach to live holders, restore sessions whose holders vanished.
    fn reconcile(self: &Arc<Self>) {
        let ids: Vec<(String, SessionState)> =
            self.state.lock().unwrap().sessions.iter().map(|s| (s.id.clone(), s.state)).collect();
        let boot = util::boot_time();
        let last_boot = self.store.lock().unwrap().get_meta("boot_time").and_then(|v| v.parse::<u64>().ok());
        let rebooted = last_boot.is_some_and(|b| b.abs_diff(boot) > 2);
        let _ = self.store.lock().unwrap().set_meta("boot_time", &boot.to_string());
        for (id, st) in ids {
            match st {
                SessionState::Running | SessionState::Interrupted => {
                    if holder_alive(&self.paths, &id) {
                        self.with_session(&id, |s| s.state = SessionState::Running);
                        self.start_monitor(&id);
                    } else {
                        // Exited while we were away?
                        let exited = std::fs::read(self.paths.holder_exit(&id)).ok().and_then(|b| serde_json::from_slice::<octomux_proto::ExitInfo>(&b).ok());
                        if let (Some(info), false) = (exited, rebooted) {
                            self.with_session(&id, |s| {
                                s.state = SessionState::Exited;
                                s.exit_code = info.code;
                            });
                        } else {
                            self.with_session(&id, |s| s.state = SessionState::Interrupted);
                            if let Err(e) = self.spawn_session(&id, true) {
                                eprintln!("[ade-daemon] restore {id} failed: {e:#}");
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        self.changed();
    }

    fn spawn_session(self: &Arc<Self>, id: &str, restoring: bool) -> Result<()> {
        if !self.spawning.lock().unwrap().insert(id.to_string()) {
            return Ok(()); // already being spawned
        }
        let r = self.spawn_session_inner(id, restoring, 120, 40);
        self.spawning.lock().unwrap().remove(id);
        r
    }

    fn spawn_session_inner(self: &Arc<Self>, id: &str, restoring: bool, cols: u16, rows: u16) -> Result<()> {
        if holder_alive(&self.paths, id) {
            self.start_monitor(id);
            return Ok(());
        }
        let (session, profile) = {
            let st = self.state.lock().unwrap();
            let s = st.sessions.iter().find(|s| s.id == id).cloned().ok_or_else(|| anyhow!("no such session {id}"))?;
            let p = s.profile_id.as_ref().and_then(|pid| st.profiles.iter().find(|p| &p.id == pid).cloned());
            (s, p)
        };
        if session.kind == SessionKind::Agent && profile.is_none() {
            bail!("agent profile for session {id} no longer exists");
        }
        let aliases = self.aliases.lock().unwrap().clone();
        let prompt = self.prompts.lock().unwrap().remove(id);
        let mut spec = agents::build_launch_with_prompt(&self.paths, &session, profile.as_ref(), restoring, &aliases, prompt.as_deref());
        if let Some(p) = self.login_path.lock().unwrap().clone() {
            spec.env.push(("PATH".into(), p));
        }
        let exe = std::env::current_exe()?;
        let mut cmd = std::process::Command::new(exe);
        cmd.arg("holder").args(["--id", id, "--cwd", &spec.cwd, "--cols", &cols.to_string(), "--rows", &rows.to_string()]);
        for (k, v) in &spec.env {
            cmd.arg("--env").arg(format!("{k}={v}"));
        }
        cmd.arg("--").args(&spec.argv);
        let log = std::fs::OpenOptions::new().create(true).append(true).open(self.paths.logs_dir().join("holders.log"))?;
        cmd.env(octomux_proto::HOME_VAR, &self.paths.home).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(log);
        {
            use std::os::unix::process::CommandExt;
            unsafe {
                cmd.pre_exec(|| {
                    libc::setsid();
                    Ok(())
                });
            }
        }
        let mut child = cmd.spawn().context("spawn holder")?;
        // Reap the holder's direct parent link in the background (it runs on its own).
        std::thread::spawn(move || {
            let _ = child.wait();
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        while !holder_alive(&self.paths, id) {
            if Instant::now() > deadline {
                bail!("holder for {id} did not come up");
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let now = util::now_secs();
        self.with_session(id, |s| {
            s.state = SessionState::Running;
            s.exit_code = None;
            s.activity = Activity::Idle;
            s.last_activity_at = now;
            if spec.agent_session_id.is_some() {
                s.agent_session_id = spec.agent_session_id.clone();
            }
        });
        self.start_monitor(id);
        // A terminal tab that had an agent conversation open when it was stopped (or crashed): reopen it in
        // the new shell, typed as the user would, so leaving the agent lands in the shell again.
        if session.kind == SessionKind::Terminal {
            if let Some(r) = session.resume_agent.as_ref().filter(|r| r.app == "claude-code") {
                let line = match &r.config_dir {
                    Some(d) => format!("CLAUDE_CONFIG_DIR={} claude --resume {}\r", util::shell_quote(d), util::shell_quote(&r.session_id)),
                    None => format!("claude --resume {}\r", util::shell_quote(&r.session_id)),
                };
                if let Ok(mut c) = HolderClient::connect(&self.paths, id, Role::Control, 0, 0) {
                    let _ = c.send(&Frame::new(Kind::Input, line.into_bytes()));
                }
                self.with_session(id, |s| s.agent_app = Some(r.app.clone()));
            }
        }
        self.changed();
        Ok(())
    }

    fn start_monitor(self: &Arc<Self>, id: &str) {
        if !self.monitored.lock().unwrap().insert(id.to_string()) {
            return;
        }
        let d = self.clone();
        let id = id.to_string();
        std::thread::spawn(move || {
            let mut exited = None;
            if let Ok(mut c) = HolderClient::connect(&d.paths, &id, Role::Monitor, 0, 0) {
                loop {
                    match c.recv() {
                        Ok(Some(f)) if f.kind == Kind::Event => {
                            if let Ok(ev) = f.parse_json::<HolderEvent>() {
                                d.on_holder_event(&id, ev);
                            }
                        }
                        Ok(Some(f)) if f.kind == Kind::Exited => {
                            exited = f.parse_json::<octomux_proto::ExitInfo>().ok();
                        }
                        Ok(Some(_)) => {}
                        _ => break,
                    }
                }
            }
            d.monitored.lock().unwrap().remove(&id);
            d.on_holder_gone(&id, exited);
        });
    }

    fn on_holder_gone(self: &Arc<Self>, id: &str, exited: Option<octomux_proto::ExitInfo>) {
        let exited = exited.or_else(|| std::fs::read(self.paths.holder_exit(id)).ok().and_then(|b| serde_json::from_slice(&b).ok()));
        let profile_id = self.with_session(id, |s| {
            match (s.state, &exited) {
                (SessionState::Stopped, _) => {}
                (_, Some(info)) => {
                    s.state = SessionState::Exited;
                    s.exit_code = info.code;
                }
                (_, None) => s.state = SessionState::Interrupted,
            }
            s.activity = Activity::Idle;
            s.profile_id.clone()
        });
        if profile_id.is_none() {
            return; // session removed
        }
        // Remember Codex conversation ids for later resume.
        if let Some(Some(pid)) = profile_id {
            let (prof, sess) = {
                let st = self.state.lock().unwrap();
                (st.profiles.iter().find(|p| p.id == pid).cloned(), st.sessions.iter().find(|s| s.id == id).cloned())
            };
            if let (Some(p), Some(s)) = (prof, sess) {
                if p.kind == AgentKind::Codex && s.agent_session_id.is_none() {
                    if let Some(cid) = agents::discover_codex_session(&p, &s.cwd, s.created_at) {
                        self.with_session(id, |s| s.agent_session_id = Some(cid));
                    }
                }
            }
        }
        self.changed();
    }

    /// Saves rate-limit readings for a profile (replacing the same windows).
    fn store_usage(&self, profile_id: &str, readings: Vec<(String, f64, Option<i64>)>) -> usize {
        if readings.is_empty() {
            return 0;
        }
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
        let n = readings.len();
        {
            let mut st = self.state.lock().unwrap();
            let store = self.store.lock().unwrap();
            for (window, pct, resets_at) in readings {
                let r = UsageReading { profile_id: profile_id.to_string(), window, used_percent: pct, resets_at, observed_at: now };
                st.usage.retain(|x| !(x.profile_id == r.profile_id && x.window == r.window));
                let _ = store.put("usage", &format!("{}:{}", r.profile_id, r.window), &r);
                st.usage.push(r);
            }
        }
        self.changed();
        n
    }

    /// Claude limits from `claude -p /usage` (a local command: no model call), per Claude profile, so the
    /// numbers are current even when no Claude session in Octomux ran a turn lately (usage from other
    /// terminals or apps counts too). One run at a time; each is cut off after 30 s.
    fn poll_claude_usage(self: &Arc<Self>, only: Option<&[String]>) {
        if octomux_proto::env_var_os("NO_USAGE_PROBE").is_some() || self.claude_usage_running.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        let profiles: Vec<Profile> = {
            let st = self.state.lock().unwrap();
            st.profiles
                .iter()
                .filter(|p| p.kind == AgentKind::Claude && p.enabled && only.is_none_or(|ids| ids.iter().any(|i| i == &p.id)))
                .cloned()
                .collect()
        };
        let aliases = self.aliases.lock().unwrap().clone();
        let path = self.login_path.lock().unwrap().clone();
        for p in profiles {
            let argv = agents::claude_usage_argv(&p, &aliases);
            let Some((exe, rest)) = argv.split_first() else { continue };
            let mut cmd = std::process::Command::new(exe);
            cmd.args(rest).current_dir(&self.paths.home).stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null());
            if let Some(path) = &path {
                cmd.env("PATH", path);
            }
            for (k, v) in &p.env {
                cmd.env(k, util::expand_tilde(v));
            }
            let Ok(mut child) = cmd.spawn() else { continue };
            let deadline = Instant::now() + Duration::from_secs(30);
            let ok = loop {
                match child.try_wait() {
                    Ok(Some(st)) => break st.success(),
                    Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(100)),
                    _ => {
                        let _ = child.kill();
                        let _ = child.wait();
                        break false;
                    }
                }
            };
            if !ok {
                continue;
            }
            let mut out = String::new();
            if let Some(mut so) = child.stdout.take() {
                use std::io::Read;
                let _ = so.read_to_string(&mut out);
            }
            let text = serde_json::from_str::<Value>(out.trim()).ok().and_then(|v| v["result"].as_str().map(String::from)).unwrap_or_default();
            let readings = agents::parse_claude_usage(&text, util::now_secs() as i64);
            self.store_usage(&p.id, readings);
        }
        self.claude_usage_running.store(false, std::sync::atomic::Ordering::SeqCst);
    }

    /// Codex rate limits from its rollout files (profiles with a running session), on `usage.refresh`.
    fn poll_codex_usage(&self, only: Option<&[String]>) {
        let profiles: Vec<Profile> = {
            let st = self.state.lock().unwrap();
            st.profiles
                .iter()
                .filter(|p| p.kind == AgentKind::Codex && only.is_none_or(|ids| ids.iter().any(|i| i == &p.id)))
                .filter(|p| st.sessions.iter().any(|s| s.profile_id.as_deref() == Some(&p.id) && s.state == SessionState::Running))
                .cloned()
                .collect()
        };
        for p in profiles {
            let r = agents::codex_rate_limits(&p);
            self.store_usage(&p.id, r);
        }
    }

    /// Picks up conversation titles agents write to their transcripts (only the new bytes each time).
    pub(crate) fn poll_agent_titles(&self) {
        let targets: Vec<(String, String)> = {
            let st = self.state.lock().unwrap();
            st.sessions
                .iter()
                .filter(|s| s.state == SessionState::Running)
                .filter_map(|s| s.transcript_path.clone().map(|p| (s.id.clone(), p)))
                .collect()
        };
        let mut updates = Vec::new();
        let mut interrupted = Vec::new();
        {
            let mut scans = self.title_scan.lock().unwrap();
            scans.retain(|id, _| targets.iter().any(|(t, _)| t == id));
            for (id, path) in targets {
                let sc = scans.entry(id.clone()).or_default();
                if sc.path != path {
                    *sc = TitleScan { path: path.clone(), ..Default::default() };
                }
                let Ok(mut f) = std::fs::File::open(&path) else { continue };
                let len = f.metadata().map(|m| m.len()).unwrap_or(0);
                if len < sc.offset {
                    *sc = TitleScan { path: path.clone(), ..Default::default() };
                }
                if len == sc.offset {
                    continue;
                }
                use std::io::{Read, Seek, SeekFrom};
                if f.seek(SeekFrom::Start(sc.offset)).is_err() {
                    continue;
                }
                let mut buf = Vec::new();
                if f.take(len - sc.offset).read_to_end(&mut buf).is_err() {
                    continue;
                }
                // Only whole lines; a partial last line is read again next time.
                let Some(end) = buf.iter().rposition(|b| *b == b'\n') else { continue };
                sc.offset += end as u64 + 1;
                let (mut c, mut a) = (sc.custom.take(), sc.ai.take());
                let chunk = String::from_utf8_lossy(&buf[..end]);
                scan_titles(&chunk, &mut c, &mut a);
                if let Some((true, ts)) = last_turn_record(&chunk) {
                    interrupted.push((id.clone(), ts));
                }
                sc.custom = c;
                sc.ai = a;
                if let Some(t) = sc.custom.clone().or_else(|| sc.ai.clone()) {
                    updates.push((id, t));
                }
            }
        }
        for (id, ts) in interrupted {
            self.on_interrupt(&id, ts);
        }
        let mut any = false;
        for (id, t) in updates {
            if self.with_session(&id, |s| {
                let changed = s.agent_title != t;
                s.agent_title = t.clone();
                changed
            }) == Some(true)
            {
                any = true;
            }
        }
        if any {
            self.changed();
        }
    }

    /// A program that reported its state (OSC 7501), or a claude a terminal tab learned about from hooks, sends
    /// no `clear` / SessionEnd when killed: find its process once, then treat its exit as that `clear`.
    pub(crate) fn check_reporting_programs(&self) {
        let reporting: Vec<(String, Option<String>)> = {
            let st = self.state.lock().unwrap();
            st.sessions
                .iter()
                // Terminal tabs only: a launched agent that dies ends its session anyway. `agent_app` is set
                // there both by reports (OSC 7501 `app`) and by hooks; a non-agent program that reports
                // (`cargo`) has an app we don't know by name and is left to its own `clear`.
                .filter(|s| s.state == SessionState::Running && s.kind != SessionKind::Agent && (s.reports_status || s.agent_app.is_some()))
                .map(|s| (s.id.clone(), s.agent_app.clone()))
                .collect()
        };
        // Only while the tab itself lives: a dead holder (crash, reboot; the daemon starting up still lists it
        // as running) is the restore's business, and must keep what it resumes.
        let reporting: Vec<(String, Option<String>)> = reporting.into_iter().filter(|(id, _)| holder_alive(&self.paths, id)).collect();
        let mut pids = self.program_pid.lock().unwrap();
        pids.retain(|id, _| reporting.iter().any(|(r, _)| r == id));
        let mut gone = Vec::new();
        for (id, app) in reporting {
            let pid = match pids.get(&id) {
                Some(p) => *p,
                None => match self.find_program_pid(&id, app.as_deref()) {
                    Some(Some(p)) => *pids.entry(id.clone()).or_insert(p),
                    Some(None) => {
                        gone.push(id); // a known app no longer running (e.g. reported before a daemon restart)
                        continue;
                    }
                    None => *pids.entry(id.clone()).or_insert(-1),
                },
            };
            if pid > 0 && unsafe { libc::kill(pid, 0) } != 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
                pids.remove(&id);
                gone.push(id);
            }
        }
        let alive: Vec<(String, i32)> = pids.iter().filter(|(_, p)| **p > 0).map(|(i, p)| (i.clone(), *p)).collect();
        drop(pids);
        for id in gone {
            self.on_holder_event(&id, HolderEvent::ProgramStatus { state: "clear".into(), app: String::new(), kind: String::new() });
        }
        // Without hooks a terminal tab's claude doesn't tell us its conversation: read Claude's own record of it
        // now and then (it changes on /clear and /resume).
        for (id, pid) in alive {
            let due = {
                let mut last = self.resume_scan.lock().unwrap();
                let t = last.entry(id.clone()).or_insert(Instant::now() - Duration::from_secs(60));
                (t.elapsed() >= Duration::from_secs(2)).then(|| *t = Instant::now()).is_some()
            };
            let needed = self.with_session(&id, |s| s.agent_app.as_deref() == Some("claude-code") && !s.resume_agent.as_ref().is_some_and(|r| r.from_hook)) == Some(true);
            if !due || !needed {
                continue;
            }
            if let Some(r) = self.find_claude_conversation(&id, pid) {
                let changed = self.with_session(&id, |s| {
                    let c = s.resume_agent.as_ref() != Some(&r);
                    s.resume_agent = Some(r.clone());
                    c
                });
                if changed == Some(true) {
                    if let Some(copy) = self.with_session(&id, |s| s.clone()) {
                        self.persist_session(&copy);
                    }
                }
            }
        }
    }

    /// The conversation a claude process works on, as Claude itself records it: `<config>/sessions/<pid>.json`
    /// (`pid`, `sessionId`, `startedAt` ms; rewritten on /clear and /resume). The start time must match the
    /// process's, so a reused pid never picks up another claude's record. No record (an older Claude): None —
    /// no resume beats resuming the wrong conversation.
    fn find_claude_conversation(&self, _id: &str, pid: i32) -> Option<ResumeAgent> {
        let started = crate::procs::start_time(pid)? as i64;
        let home = util::home_dir();
        let mut configs = vec![home.join(".claude")];
        if let Ok(rd) = std::fs::read_dir(&home) {
            configs.extend(rd.flatten().filter(|e| e.file_name().to_string_lossy().starts_with(".claude-") && e.path().is_dir()).map(|e| e.path()));
        }
        for cfg in configs {
            let Ok(text) = std::fs::read_to_string(cfg.join("sessions").join(format!("{pid}.json"))) else { continue };
            let Some(r) = claude_session_record(&text, pid, started) else { continue };
            return Some(ResumeAgent { app: "claude-code".into(), session_id: r, config_dir: (cfg != home.join(".claude")).then(|| cfg.to_string_lossy().into_owned()), from_hook: false });
        }
        None
    }

    /// The reporting program among the session's processes: the shallowest descendant of its shell named
    /// like the app (`claude` for claude-code; Claude's binary lives in `…/claude/versions/<v>`).
    /// None: can't tell (unknown app, no holder info, ps failed); Some(None): a known app that is not running.
    fn find_program_pid(&self, id: &str, app: Option<&str>) -> Option<Option<i32>> {
        let names: &[&str] = match app? {
            "claude-code" | "claude" => &["claude"],
            "codex" => &["codex"],
            _ => return None,
        };
        let info: Value = serde_json::from_str(&std::fs::read_to_string(self.paths.holder_info(id)).ok()?).ok()?;
        let root = info.get("child_pid")?.as_i64()? as i32;
        let out = std::process::Command::new("ps").args(["-A", "-o", "pid=,ppid=,comm="]).output().ok()?;
        let rows: Vec<(i32, i32, String)> = String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|l| {
                let mut it = l.split_whitespace();
                Some((it.next()?.parse().ok()?, it.next()?.parse().ok()?, it.collect::<Vec<_>>().join(" ")))
            })
            .collect();
        let matches = |comm: &str| {
            let base = comm.rsplit('/').next().unwrap_or(comm);
            names.contains(&base) || (names.contains(&"claude") && comm.contains("/claude/versions/"))
        };
        // Breadth-first from the shell, so an agent's own nested `claude -p` (deeper) is never picked.
        let mut level = vec![root];
        for _ in 0..8 {
            if let Some(p) = rows.iter().find(|(pid, _, c)| level.contains(pid) && matches(c)) {
                return Some(Some(p.0));
            }
            level = rows.iter().filter(|(_, pp, _)| level.contains(pp)).map(|(pid, _, _)| *pid).collect();
            if level.is_empty() {
                break;
            }
        }
        Some(None)
    }

    /// You pressed Esc in a Claude session (its transcript says so): it is no longer working or waiting for you.
    /// A marker from before the last state change (an old turn, or one read late) changes nothing.
    fn on_interrupt(&self, id: &str, ts: Option<u64>) {
        let since = self.activity_at.lock().unwrap().get(id).copied().unwrap_or(0);
        if ts.is_some_and(|t| t + 500 < since) {
            return;
        }
        let busy = self.with_session(id, |s| !s.reports_status && matches!(s.activity, Activity::Working | Activity::NeedsInput)) == Some(true);
        if busy {
            self.set_activity(id, Activity::Idle);
            // You were there to press Esc: nothing to come back to.
            if self.with_session(id, |s| std::mem::replace(&mut s.unread, false)) == Some(true) {
                self.changed();
            }
        }
    }

    fn set_activity(&self, id: &str, new: Activity) {
        let info = {
            let mut st = self.state.lock().unwrap();
            let Some(s) = st.sessions.iter_mut().find(|s| s.id == id) else { return };
            if s.activity == new {
                return;
            }
            s.activity = new;
            s.last_activity_at = util::now_secs();
            self.activity_at.lock().unwrap().insert(id.to_string(), util::now_millis());
            if matches!(new, Activity::Done | Activity::NeedsInput | Activity::Error) {
                s.unread = true;
                if let (SessionKind::Agent, Some(pid)) = (s.kind, s.profile_id.clone()) {
                    let mut poke = self.usage_poke.lock().unwrap();
                    let mut ids = poke.take().map(|(_, ids)| ids).unwrap_or_default();
                    if !ids.contains(&pid) {
                        ids.push(pid);
                    }
                    *poke = Some((Instant::now(), ids));
                }
            }
            let copy = s.clone();
            let project = st.projects.iter().find(|p| p.id == copy.project_id).map(|p| p.name.clone()).unwrap_or_default();
            let profile = copy.profile_id.as_ref().and_then(|pid| st.profiles.iter().find(|p| &p.id == pid)).map(|p| p.name.clone());
            drop(st);
            self.persist_session(&copy);
            (copy, project, profile)
        };
        let (s, project, profile) = info;
        let name = if !s.custom_title.is_empty() { s.custom_title.clone() } else if !s.agent_title.is_empty() { s.agent_title.clone() } else if !s.title.is_empty() { s.title.clone() } else { profile.clone().unwrap_or("Session".into()) };
        let agent = profile.or_else(|| s.agent_app.as_deref().map(app_label)).unwrap_or_else(|| "Terminal".into());
        let note = match new {
            Activity::Done => Some(("done", format!("{agent} finished"), format!("{project} · {name}"))),
            Activity::NeedsInput => Some(("needs_input", format!("{agent} needs your input"), format!("{project} · {name}"))),
            Activity::Error => Some(("error", format!("{agent} hit an error"), format!("{project} · {name}"))),
            _ => None,
        };
        if let Some((kind, title, body)) = note {
            if self.notifications_enabled(&s.project_id, kind) {
                self.notify(Notification { session_id: s.id.clone(), project_id: s.project_id.clone(), kind: kind.into(), title, body });
            }
        }
        self.changed();
    }

    fn notifications_enabled(&self, project_id: &str, kind: &str) -> bool {
        if self.setting("notifications.enabled", Some(project_id)).and_then(|v| v.as_bool()) == Some(false) {
            return false;
        }
        self.setting(&format!("notifications.{kind}"), Some(project_id)).and_then(|v| v.as_bool()) != Some(false)
    }

    fn on_holder_event(&self, id: &str, ev: HolderEvent) {
        match ev {
            HolderEvent::Title { title } => {
                let t = strip_title(&title);
                let changed = self.with_session(id, |s| {
                    // Actions keep their name; the shell inside would otherwise rename them.
                    if s.kind != SessionKind::Action && s.title != t && !t.is_empty() {
                        s.title = t.clone();
                        true
                    } else {
                        false
                    }
                });
                if changed == Some(true) {
                    self.changed();
                }
            }
            // OSC 7501 from the program itself (Claude Code 2.1.296+ once we answer its probe): the most exact
            // source, so it takes over from hooks/transcript/Enter. `clear` = the program exited.
            HolderEvent::ProgramStatus { state, app, kind } => {
                if std::env::var_os("OCTOMUX_TRACE_STATUS").is_some() {
                    eprintln!("[status] {} {id} {state} {app} {kind}", util::now_millis());
                }
                let a = match state.as_str() {
                    "working" => Activity::Working,
                    "blocked" => Activity::NeedsInput,
                    "done" => Activity::Done,
                    "error" => Activity::Error,
                    _ => Activity::Idle,
                };
                let gone = state == "clear";
                if gone {
                    self.program_pid.lock().unwrap().remove(id);
                }
                let changed = self.with_session(id, |s| {
                    let before = (s.reports_status, s.agent_app.clone());
                    s.reports_status = !gone;
                    // Only agents make a terminal tab an agent; a build tool reporting progress just sets its state.
                    // A `clear` while the tab is being stopped or restarted (the agent dies with the shell) keeps
                    // it an agent, to resume on restore; one while it runs means the agent exited (`/exit`).
                    if s.kind != SessionKind::Agent {
                        if !gone {
                            s.agent_app = is_agent_app(&app).then(|| app.clone());
                        } else if s.state == SessionState::Running {
                            s.agent_app = None;
                            s.resume_agent = None;
                        }
                    }
                    before != (s.reports_status, s.agent_app.clone())
                });
                if changed == Some(true) {
                    if let Some(copy) = self.with_session(id, |s| s.clone()) {
                        self.persist_session(&copy);
                    }
                    self.changed();
                }
                self.set_activity(id, a);
            }
            HolderEvent::Notify { title, body } => {
                let (pid, name) = {
                    let st = self.state.lock().unwrap();
                    let s = st.sessions.iter().find(|s| s.id == id);
                    (s.map(|s| s.project_id.clone()).unwrap_or_default(), s.map(|s| s.title.clone()).unwrap_or_default())
                };
                if self.notifications_enabled(&pid, "program") {
                    let title = if title.is_empty() { name } else { title };
                    self.notify(Notification { session_id: id.into(), project_id: pid, kind: "program".into(), title, body });
                }
            }
            HolderEvent::Command { phase, exit_code } => match phase.as_str() {
                "start" => {
                    self.cmd_started.lock().unwrap().insert(id.to_string(), Instant::now());
                }
                "end" => {
                    let started = self.cmd_started.lock().unwrap().remove(id);
                    let Some(t0) = started else { return };
                    let secs = t0.elapsed().as_secs();
                    let (pid, kind, title) = {
                        let st = self.state.lock().unwrap();
                        let Some(s) = st.sessions.iter().find(|s| s.id == id) else { return };
                        (s.project_id.clone(), s.kind, s.title.clone())
                    };
                    let threshold = self.setting("notifications.command_threshold_secs", Some(&pid)).and_then(|v| v.as_u64()).unwrap_or(10);
                    if kind != SessionKind::Agent && secs >= threshold && self.notifications_enabled(&pid, "command_done") {
                        let ok = exit_code.unwrap_or(0) == 0;
                        self.notify(Notification {
                                session_id: id.into(),
                                project_id: pid,
                                kind: "command_done".into(),
                                title: if ok { "Command finished".into() } else { format!("Command failed (exit {})", exit_code.unwrap_or(-1)) },
                                body: format!("{title} · {secs}s"),
                            });
                    }
                }
                _ => {}
            },
            HolderEvent::Cwd { path } => {
                let changed = self.with_session(id, |s| {
                    if s.kind == SessionKind::Terminal && s.cwd != path {
                        s.cwd = path.clone();
                        true
                    } else {
                        false
                    }
                });
                if changed == Some(true) {
                    self.changed();
                }
            }
            HolderEvent::Activity => {
                let now = util::now_secs();
                let mut st = self.state.lock().unwrap();
                if let Some(s) = st.sessions.iter_mut().find(|s| s.id == id) {
                    s.last_activity_at = now;
                }
            }
            HolderEvent::Bell => {}
            // Enter while an agent waits on a permission or question dialog: you answered it, so it works on.
            // (Answering "No" makes Claude write an interrupt marker; the transcript scan then sets it idle.)
            HolderEvent::Submit => {
                if self.with_session(id, |s| s.is_agent() && !s.reports_status && s.activity == Activity::NeedsInput) == Some(true) {
                    self.set_activity(id, Activity::Working);
                }
            }
        }
    }

    fn on_hook(self: &Arc<Self>, id: &str, event: &str, payload: &Value) {
        if std::env::var_os("OCTOMUX_TRACE_STATUS").is_some() {
            eprintln!("[hook] {} {id} {event} {}", util::now_millis(), payload.get("session_id").and_then(|v| v.as_str()).unwrap_or(""));
        }
        // (Nested claudes an agent runs are filtered out by the hook command itself, see procs::claude_ancestors.)
        let cid = payload.get("session_id").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let launched = self.with_session(id, |s| s.kind == SessionKind::Agent).unwrap_or(false);
        if let Some(tp) = payload.get("transcript_path").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
            let tp = tp.to_string();
            if self.with_session(id, |s| {
                let changed = s.transcript_path.as_deref() != Some(&tp);
                s.transcript_path = Some(tp.clone());
                changed
            }) == Some(true)
            {
                self.changed();
            }
        }
        // A claude typed in a terminal tab (hooks installed globally): the tab shows as an agent until it exits.
        if !launched && matches!(event, "SessionStart" | "SessionEnd") {
            let start = event == "SessionStart";
            // A SessionEnd from a claude that died with its tab (killed holder, crash; often replayed from the
            // spool once we're back) is not the user leaving claude: keep it to resume on restore.
            if !start && !holder_alive(&self.paths, id) {
                return;
            }
            let changed = self.with_session(id, |s| {
                let before = s.agent_app.clone();
                if start {
                    s.agent_app.get_or_insert_with(|| "claude-code".into());
                    if !cid.is_empty() {
                        // <config>/projects/<cwd>/<id>.jsonl → <config>, kept only when not ~/.claude.
                        let cfg = s.transcript_path.as_deref().and_then(|t| std::path::Path::new(t).ancestors().nth(3)).map(|p| p.to_path_buf());
                        let cfg = cfg.filter(|c| *c != util::home_dir().join(".claude")).map(|c| c.to_string_lossy().into_owned());
                        s.resume_agent = Some(ResumeAgent { app: "claude-code".into(), session_id: cid.clone(), config_dir: cfg, from_hook: true });
                    }
                } else if s.state == SessionState::Running {
                    s.agent_app = None;
                    s.resume_agent = None;
                    s.transcript_path = None;
                    s.agent_title.clear();
                }
                before != s.agent_app
            });
            if changed == Some(true) {
                if let Some(copy) = self.with_session(id, |s| s.clone()) {
                    self.persist_session(&copy);
                }
                self.changed();
            }
        }
        if event == "SessionStart" && launched && !cid.is_empty() {
            let changed = self.with_session(id, |s| {
                if s.agent_session_id.as_deref() != Some(&cid) {
                    s.agent_session_id = Some(cid.clone());
                    true
                } else {
                    false
                }
            });
            if changed == Some(true) {
                self.changed();
            }
        }
        // The program reports its own state (OSC 7501): hooks then only carry identity, with one exception.
        // Claude reports `done` only after every Stop hook has finished (a slow one, like a `say`, delays it
        // by seconds), while our Stop hook runs alongside them: let it mark the turn done early. A Stop hook
        // that makes Claude go on (decision: block) leaves Claude's own state at working, so no new report
        // comes; a tool hook after such an early done puts it back to working.
        if let Some(cur) = self.with_session(id, |s| s.reports_status.then_some(s.activity)).flatten() {
            match (event, cur) {
                ("Stop", Activity::Working) => self.set_activity(id, Activity::Done),
                ("PreToolUse" | "PostToolUse", Activity::Done) => self.set_activity(id, Activity::Working),
                _ => {}
            }
            return;
        }
        match event {
            "SessionStart" => self.set_activity(id, Activity::Idle),
            // PostToolUse: a tool you approved has run, so the agent is working again (no hook marks the approval).
            "UserPromptSubmit" | "PreToolUse" | "PostToolUse" => self.set_activity(id, Activity::Working),
            "PermissionRequest" => self.set_activity(id, Activity::NeedsInput),
            "Notification" => {
                let ty = payload.get("notification_type").and_then(|v| v.as_str()).unwrap_or("");
                let msg = payload.get("message").and_then(|v| v.as_str()).unwrap_or("");
                if matches!(ty, "permission_prompt" | "elicitation_dialog") || (ty.is_empty() && msg.to_lowercase().contains("permission")) {
                    self.set_activity(id, Activity::NeedsInput);
                }
            }
            "Stop" => self.set_activity(id, Activity::Done),
            "SessionEnd" => self.set_activity(id, Activity::Idle),
            _ => {}
        }
    }

    fn serve(self: Arc<Self>, stream: UnixStream) -> Result<()> {
        let reader = BufReader::new(stream.try_clone()?);
        let (tx, rx) = channel::<String>();
        let mut w = stream.try_clone()?;
        std::thread::spawn(move || {
            for line in rx {
                if w.write_all(line.as_bytes()).is_err() || w.write_all(b"\n").is_err() {
                    break;
                }
            }
        });
        for line in reader.lines() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            let req: Request = match serde_json::from_str(&line) {
                Ok(r) => r,
                Err(e) => {
                    let _ = tx.send(serde_json::to_string(&json!({ "id": 0, "error": format!("bad request: {e}") }))?);
                    continue;
                }
            };
            if req.method == "subscribe" {
                self.subs.lock().unwrap().push(tx.clone());
                let s = serde_json::to_value(&*self.state.lock().unwrap())?;
                let _ = tx.send(serde_json::to_string(&json!({ "id": req.id, "result": s }))?);
                continue;
            }
            let resp = match self.dispatch(&req.method, &req.params) {
                Ok(v) => json!({ "id": req.id, "result": v }),
                Err(e) => json!({ "id": req.id, "error": format!("{e:#}") }),
            };
            let _ = tx.send(serde_json::to_string(&resp)?);
            if req.method == "daemon.shutdown" {
                std::thread::sleep(Duration::from_millis(100));
                let _ = std::fs::remove_file(self.paths.daemon_socket());
                std::process::exit(0);
            }
        }
        Ok(())
    }

    fn dispatch(self: &Arc<Self>, method: &str, p: &Value) -> Result<Value> {
        let s = |k: &str| p.get(k).and_then(|v| v.as_str()).map(|v| v.to_string());
        let req = |k: &str| s(k).ok_or_else(|| anyhow!("missing param {k}"));
        match method {
            "hello" => Ok(json!({ "version": octomux_proto::PROTOCOL_VERSION, "pid": std::process::id(), "home": self.paths.home })),
            "state.get" => Ok(serde_json::to_value(&*self.state.lock().unwrap())?),
            "daemon.shutdown" => Ok(json!({ "ok": true })),

            "workspace.create" => {
                let mut st = self.state.lock().unwrap();
                let w = Workspace {
                    id: util::short_id(),
                    name: s("name").unwrap_or("Workspace".into()),
                    color: s("color").unwrap_or_else(|| PROJECT_COLORS[st.workspaces.len() % PROJECT_COLORS.len()].into()),
                    sort: st.workspaces.iter().map(|w| w.sort).max().unwrap_or(-1) + 1,
                    icon: s("icon").filter(|s| !s.is_empty()),
                };
                st.workspaces.push(w.clone());
                self.store.lock().unwrap().put("workspace", &w.id, &w)?;
                drop(st);
                self.changed();
                Ok(serde_json::to_value(w)?)
            }
            "workspace.update" => {
                let id = req("id")?;
                let mut st = self.state.lock().unwrap();
                let w = st.workspaces.iter_mut().find(|w| w.id == id).ok_or_else(|| anyhow!("no workspace"))?;
                if let Some(v) = s("name") {
                    w.name = v;
                }
                if let Some(v) = s("color") {
                    w.color = v;
                }
                if let Some(v) = p.get("sort").and_then(|v| v.as_i64()) {
                    w.sort = v;
                }
                if let Some(v) = p.get("icon") {
                    w.icon = v.as_str().filter(|s| !s.is_empty()).map(String::from);
                }
                let w = w.clone();
                st.workspaces.sort_by_key(|w| w.sort);
                self.store.lock().unwrap().put("workspace", &w.id, &w)?;
                drop(st);
                self.changed();
                Ok(serde_json::to_value(w)?)
            }
            "workspace.delete" => {
                let id = req("id")?;
                let projects: Vec<String> = {
                    let st = self.state.lock().unwrap();
                    if st.workspaces.len() <= 1 {
                        bail!("cannot delete the last workspace");
                    }
                    st.projects.iter().filter(|p| p.workspace_id == id).map(|p| p.id.clone()).collect()
                };
                for pid in projects {
                    self.delete_project(&pid)?;
                }
                self.state.lock().unwrap().workspaces.retain(|w| w.id != id);
                self.store.lock().unwrap().delete("workspace", &id)?;
                self.changed();
                Ok(json!({ "ok": true }))
            }

            "project.create" => {
                let ws = req("workspace_id")?;
                let path = util::expand_tilde(&req("path")?);
                let pb = std::path::PathBuf::from(&path);
                if !pb.is_dir() {
                    bail!("not a directory: {path}");
                }
                let path = pb.canonicalize().unwrap_or(pb).to_string_lossy().into_owned();
                let mut st = self.state.lock().unwrap();
                if !st.workspaces.iter().any(|w| w.id == ws) {
                    bail!("no workspace {ws}");
                }
                let name = s("name").unwrap_or_else(|| std::path::Path::new(&path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or(path.clone()));
                let pr = Project {
                    id: util::short_id(),
                    workspace_id: ws,
                    name,
                    path,
                    color: s("color").unwrap_or_else(|| PROJECT_COLORS[st.projects.len() % PROJECT_COLORS.len()].into()),
                    icon: p.get("icon").cloned().unwrap_or(json!({ "kind": "folder" })),
                    sort: st.projects.iter().map(|p| p.sort).max().unwrap_or(-1) + 1,
                    archived: false,
                };
                st.projects.push(pr.clone());
                self.store.lock().unwrap().put("project", &pr.id, &pr)?;
                drop(st);
                self.changed();
                Ok(serde_json::to_value(pr)?)
            }
            "project.update" => {
                let id = req("id")?;
                let mut st = self.state.lock().unwrap();
                let pr = st.projects.iter_mut().find(|x| x.id == id).ok_or_else(|| anyhow!("no project"))?;
                if let Some(v) = s("name") {
                    pr.name = v;
                }
                if let Some(v) = s("color") {
                    pr.color = v;
                }
                if let Some(v) = p.get("icon") {
                    pr.icon = v.clone();
                }
                if let Some(v) = s("workspace_id") {
                    pr.workspace_id = v;
                }
                if let Some(v) = p.get("sort").and_then(|v| v.as_i64()) {
                    pr.sort = v;
                }
                if let Some(v) = p.get("archived").and_then(|v| v.as_bool()) {
                    pr.archived = v;
                }
                let pr = pr.clone();
                st.projects.sort_by_key(|p| p.sort);
                self.store.lock().unwrap().put("project", &pr.id, &pr)?;
                drop(st);
                self.changed();
                Ok(serde_json::to_value(pr)?)
            }
            "project.delete" => {
                self.delete_project(&req("id")?)?;
                self.changed();
                Ok(json!({ "ok": true }))
            }

            "profile.create" | "profile.update" => {
                let mut prof: Profile = if method == "profile.create" {
                    let mut v = p.clone();
                    let obj = v.as_object_mut().ok_or_else(|| anyhow!("params must be an object"))?;
                    obj.insert("id".into(), json!(util::short_id()));
                    obj.entry("icon").or_insert(json!("terminal"));
                    obj.entry("kind").or_insert(json!("generic"));
                    obj.entry("enabled").or_insert(json!(true));
                    obj.entry("pinned").or_insert(json!(false));
                    obj.entry("via_login_shell").or_insert(json!(true));
                    let sort = self.state.lock().unwrap().profiles.iter().map(|p| p.sort).max().unwrap_or(-1) + 1;
                    obj.entry("sort").or_insert(json!(sort));
                    serde_json::from_value(v)?
                } else {
                    let id = req("id")?;
                    let st = self.state.lock().unwrap();
                    let cur = st.profiles.iter().find(|x| x.id == id).ok_or_else(|| anyhow!("no profile"))?;
                    let mut merged = serde_json::to_value(cur)?;
                    for (k, v) in p.as_object().into_iter().flatten() {
                        merged[k] = v.clone();
                    }
                    serde_json::from_value(merged)?
                };
                prof.name = prof.name.trim().to_string();
                if prof.name.is_empty() {
                    prof.name = prof.command.clone();
                }
                let mut st = self.state.lock().unwrap();
                st.profiles.retain(|x| x.id != prof.id);
                st.profiles.push(prof.clone());
                st.profiles.sort_by_key(|p| p.sort);
                self.store.lock().unwrap().put("profile", &prof.id, &prof)?;
                drop(st);
                self.changed();
                Ok(serde_json::to_value(prof)?)
            }
            // The optional Claude integration per Claude profile (Settings → Agents): status, install, uninstall.
            "integration.status" => {
                let aliases = self.aliases.lock().unwrap().clone();
                let script = integration::script_path(&self.paths);
                let st = self.state.lock().unwrap();
                let list: Vec<Value> = st
                    .profiles
                    .iter()
                    .filter(|p| p.kind == AgentKind::Claude)
                    .map(|p| {
                        let dir = agents::claude_config_dir_resolved(p, &aliases);
                        json!({ "profile_id": p.id, "config_dir": dir, "status": integration::status(&dir, &script) })
                    })
                    .collect();
                Ok(json!({ "profiles": list, "version": integration::VERSION }))
            }
            "integration.install" | "integration.uninstall" => {
                let pid = req("profile_id")?;
                let aliases = self.aliases.lock().unwrap().clone();
                let profile = self.state.lock().unwrap().profiles.iter().find(|p| p.id == pid).cloned().ok_or_else(|| anyhow!("no profile {pid}"))?;
                if profile.kind != AgentKind::Claude {
                    bail!("only Claude profiles have an integration");
                }
                let dir = agents::claude_config_dir_resolved(&profile, &aliases);
                let script = integration::script_path(&self.paths);
                let backup = if method == "integration.install" { integration::install(&dir, &script)? } else { integration::uninstall(&dir, &script)? };
                Ok(json!({ "config_dir": dir, "status": integration::status(&dir, &script), "backup": backup }))
            }
            "profile.delete" => {
                let id = req("id")?;
                self.state.lock().unwrap().profiles.retain(|x| x.id != id);
                self.store.lock().unwrap().delete("profile", &id)?;
                self.changed();
                Ok(json!({ "ok": true }))
            }
            "profile.detect" => {
                let path = self.login_path.lock().unwrap().clone().or_else(agents::login_shell_path).unwrap_or_default();
                let mut found: Vec<Value> = agents::KNOWN_AGENTS
                    .iter()
                    .map(|(cmd, icon, kind)| {
                        let at = agents::which(cmd, &path);
                        json!({ "command": cmd, "icon": icon, "kind": kind, "installed": at.is_some(), "path": at })
                    })
                    .collect();
                // Shell aliases that start an agent, e.g. a second Claude account.
                let aliases = agents::login_aliases();
                *self.aliases.lock().unwrap() = aliases.clone();
                for (name, value) in aliases {
                    if let Some((kind, icon)) = agents::alias_agent(&value) {
                        found.push(json!({ "command": name, "icon": icon, "kind": kind, "installed": true, "path": format!("alias: {value}"), "alias": true }));
                    }
                }
                Ok(json!(found))
            }
            "profile.check" => {
                let cmd = req("command")?;
                let path = self.login_path.lock().unwrap().clone().unwrap_or_default();
                Ok(json!({ "path": agents::which(&cmd, &path) }))
            }

            "settings.set" => {
                let scope = s("scope").unwrap_or("global".into());
                let key = req("key")?;
                let value = p.get("value").cloned().unwrap_or(Value::Null);
                let mut st = self.state.lock().unwrap();
                st.settings.retain(|x| !(x.scope == scope && x.key == key));
                let skey = format!("{scope}|{key}");
                if value.is_null() {
                    self.store.lock().unwrap().delete("setting", &skey)?;
                } else {
                    let setting = Setting { scope, key, value };
                    self.store.lock().unwrap().put("setting", &skey, &setting)?;
                    st.settings.push(setting);
                }
                drop(st);
                self.changed();
                Ok(json!({ "ok": true }))
            }

            "session.create" => self.create_session(p),
            "session.ensure" => {
                let id = req("id")?;
                let state = self.state.lock().unwrap().sessions.iter().find(|s| s.id == id).map(|s| s.state);
                match state {
                    None => bail!("no such session"),
                    Some(SessionState::Stopped) => bail!("session is stopped"),
                    _ => {
                        if !holder_alive(&self.paths, &id) {
                            let restoring = state != Some(SessionState::Exited);
                            self.spawn_session(&id, restoring)?;
                        }
                        Ok(json!({ "ok": true }))
                    }
                }
            }
            "session.stop" => {
                let id = req("id")?;
                self.with_session(&id, |s| {
                    s.state = SessionState::Stopped;
                    s.activity = Activity::Idle;
                })
                .ok_or_else(|| anyhow!("no such session"))?;
                let _ = HolderClient::request(&self.paths, &id, &HolderRequest::Kill);
                self.changed();
                Ok(json!({ "ok": true }))
            }
            "session.restart" => {
                let id = req("id")?;
                // Marked before the kill: what the dying program reports (an agent's `clear`) is not an exit.
                self.with_session(&id, |s| s.state = SessionState::Interrupted).ok_or_else(|| anyhow!("no such session"))?;
                if holder_alive(&self.paths, &id) {
                    let _ = HolderClient::request(&self.paths, &id, &HolderRequest::Kill);
                    let deadline = Instant::now() + Duration::from_secs(5);
                    while holder_alive(&self.paths, &id) && Instant::now() < deadline {
                        std::thread::sleep(Duration::from_millis(50));
                    }
                }
                self.with_session(&id, |s| s.state = SessionState::Interrupted).ok_or_else(|| anyhow!("no such session"))?;
                self.spawn_session(&id, true)?;
                Ok(json!({ "ok": true }))
            }
            "session.remove" => {
                let id = req("id")?;
                self.remove_session(&id)?;
                self.changed();
                Ok(json!({ "ok": true }))
            }
            "session.rename" => {
                let id = req("id")?;
                let t = s("title").unwrap_or_default();
                self.with_session(&id, |s| s.custom_title = t).ok_or_else(|| anyhow!("no such session"))?;
                self.changed();
                Ok(json!({ "ok": true }))
            }
            "session.mark_read" => {
                let id = req("id")?;
                let changed = self.with_session(&id, |s| {
                    let was = s.unread;
                    s.unread = false;
                    if s.activity == Activity::Done {
                        s.activity = Activity::Idle;
                    }
                    was
                });
                if changed == Some(true) {
                    self.changed();
                }
                if self.store.lock().unwrap().mark_notifications_read(None, Some(&id)).unwrap_or(0) > 0 {
                    self.notifications_changed();
                }
                Ok(json!({ "ok": true }))
            }
            "notifications.list" => {
                let limit = p.get("limit").and_then(|v| v.as_i64()).unwrap_or(200);
                Ok(json!({ "notifications": self.store.lock().unwrap().notifications(limit)? }))
            }
            "notifications.read" => {
                // ids: [..] | session_id | nothing = all
                let ids: Option<Vec<i64>> = p.get("ids").and_then(|v| serde_json::from_value(v.clone()).ok());
                let sid = s("session_id");
                let n = self.store.lock().unwrap().mark_notifications_read(ids.as_deref(), sid.as_deref())?;
                if n > 0 {
                    self.notifications_changed();
                }
                Ok(json!({ "ok": true, "changed": n }))
            }
            "notifications.clear" => {
                self.store.lock().unwrap().clear_notifications()?;
                self.notifications_changed();
                Ok(json!({ "ok": true }))
            }
            "history.list" => {
                let limit = p.get("limit").and_then(|v| v.as_i64()).unwrap_or(300);
                let pid = s("project_id");
                let items = self.store.lock().unwrap().history(pid.as_deref(), limit)?;
                Ok(json!({ "sessions": items }))
            }
            "history.delete" => {
                let id = req("id")?;
                self.store.lock().unwrap().delete_history(&id)?;
                Ok(json!({ "ok": true }))
            }
            "session.move" => {
                // Move between tab and dock placement.
                let id = req("id")?;
                let placement: Placement = serde_json::from_value(p.get("placement").cloned().unwrap_or(json!("tab")))?;
                let project_id = self.with_session(&id, |s| {
                    s.placement = placement;
                    s.project_id.clone()
                });
                let Some(project_id) = project_id else { bail!("no such session") };
                self.detach_from_tabs(&id);
                if placement == Placement::Tab {
                    self.new_tab(&project_id, &id);
                }
                self.changed();
                Ok(json!({ "ok": true }))
            }
            "session.input" => {
                let id = req("id")?;
                let data = req("data")?;
                let mut c = HolderClient::connect(&self.paths, &id, Role::Control, 0, 0)?;
                c.send(&Frame::new(Kind::Input, data.into_bytes()))?;
                Ok(json!({ "ok": true }))
            }
            "session.screen_text" => {
                let id = req("id")?;
                Ok(HolderClient::request(&self.paths, &id, &HolderRequest::ScreenText)?)
            }
            "session.info" => {
                let id = req("id")?;
                Ok(HolderClient::request(&self.paths, &id, &HolderRequest::Info)?)
            }

            "tab.update" => {
                let id = req("id")?;
                let mut st = self.state.lock().unwrap();
                let t = st.tabs.iter_mut().find(|t| t.id == id).ok_or_else(|| anyhow!("no tab"))?;
                if let Some(l) = p.get("layout") {
                    t.layout = serde_json::from_value(l.clone())?;
                }
                if let Some(a) = p.get("active_session_id") {
                    t.active_session_id = a.as_str().map(String::from);
                }
                if let Some(v) = p.get("sort").and_then(|v| v.as_i64()) {
                    t.sort = v;
                }
                let t = t.clone();
                st.tabs.sort_by_key(|t| t.sort);
                self.store.lock().unwrap().put("tab", &t.id, &t)?;
                drop(st);
                self.changed();
                Ok(serde_json::to_value(t)?)
            }
            "pane.move" => {
                // Moves a tab session next to another pane (edge left/right/top/bottom), or into a tab of its own
                // (`new_tab`). The session keeps running; tabs left empty disappear.
                let sid = req("session_id")?;
                let project_id = {
                    let st = self.state.lock().unwrap();
                    let s = st.sessions.iter().find(|s| s.id == sid).ok_or_else(|| anyhow!("no session"))?;
                    if s.placement != Placement::Tab {
                        bail!("only tab sessions can be moved between panes");
                    }
                    s.project_id.clone()
                };
                if p.get("new_tab").and_then(|v| v.as_bool()).unwrap_or(false) {
                    self.detach_from_tabs(&sid);
                    let t = self.new_tab(&project_id, &sid);
                    self.changed();
                    return Ok(serde_json::to_value(t)?);
                }
                let target = req("target_session_id")?;
                if target == sid {
                    return Ok(json!({ "ok": true }));
                }
                let edge = p.get("edge").and_then(|v| v.as_str()).unwrap_or("right");
                let (dir, before) = match edge {
                    "left" => (SplitDir::Right, true),
                    "top" => (SplitDir::Down, true),
                    "bottom" => (SplitDir::Down, false),
                    _ => (SplitDir::Right, false),
                };
                {
                    let st = self.state.lock().unwrap();
                    let tt = st.tabs.iter().find(|t| t.layout.sessions().contains(&target)).ok_or_else(|| anyhow!("target is not in a tab"))?;
                    if tt.project_id != project_id {
                        bail!("panes can only move within a project");
                    }
                }
                self.detach_from_tabs(&sid);
                let mut st = self.state.lock().unwrap();
                let t = st.tabs.iter_mut().find(|t| t.layout.sessions().contains(&target)).ok_or_else(|| anyhow!("target is not in a tab"))?;
                let (layout, done) = t.layout.clone().insert(&target, &sid, dir, before);
                if !done {
                    bail!("target pane not found");
                }
                t.layout = layout;
                t.active_session_id = Some(sid.clone());
                let t = t.clone();
                drop(st);
                self.store.lock().unwrap().put("tab", &t.id, &t)?;
                self.changed();
                Ok(serde_json::to_value(t)?)
            }
            "tab.close" => {
                let id = req("id")?;
                let sessions = self.state.lock().unwrap().tabs.iter().find(|t| t.id == id).map(|t| t.layout.sessions()).unwrap_or_default();
                for sid in sessions {
                    self.remove_session(&sid)?;
                }
                self.state.lock().unwrap().tabs.retain(|t| t.id != id);
                self.store.lock().unwrap().delete("tab", &id)?;
                self.changed();
                Ok(json!({ "ok": true }))
            }
            "git.run" => {
                // Git for clients on other machines (remote hosts): `git -C <cwd> <args…>`, allowlisted.
                const ALLOWED: &[&str] = &["status", "diff", "log", "show", "ls-files", "rev-parse", "worktree", "add", "commit", "push", "branch", "restore", "checkout", "switch", "for-each-ref", "merge-base", "remote"];
                let cwd = util::expand_tilde(&req("cwd")?);
                let args: Vec<String> = p.get("args").and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
                let sub = args.first().cloned().unwrap_or_default();
                if !ALLOWED.contains(&sub.as_str()) {
                    bail!("git {sub} is not allowed");
                }
                let out = std::process::Command::new("git").arg("-C").arg(&cwd).args(&args).stdin(std::process::Stdio::null()).output()?;
                let mut stdout = String::from_utf8_lossy(&out.stdout).into_owned();
                if stdout.len() > 2_000_000 {
                    stdout.truncate(2_000_000);
                }
                Ok(json!({ "ok": out.status.success(), "code": out.status.code(), "stdout": stdout, "stderr": String::from_utf8_lossy(&out.stderr) }))
            }
            "fs.read" => {
                // File preview for remote clients: first `max` bytes (default 512 KiB).
                let path = util::expand_tilde(&req("path")?);
                let max = p.get("max").and_then(|v| v.as_u64()).unwrap_or(512 * 1024).min(4 * 1024 * 1024) as usize;
                let offset = p.get("offset").and_then(|v| v.as_u64()).unwrap_or(0);
                use std::io::{Read, Seek};
                let mut f = std::fs::File::open(&path)?;
                let size = f.metadata()?.len();
                if offset > 0 {
                    f.seek(std::io::SeekFrom::Start(offset.min(size)))?;
                }
                let mut buf = Vec::new();
                f.take(max as u64).read_to_end(&mut buf)?;
                let binary = buf.iter().take(8000).any(|b| *b == 0);
                let read = buf.len() as u64;
                Ok(json!({ "size": size, "binary": binary, "text": if binary { String::new() } else { String::from_utf8_lossy(&buf).into_owned() }, "truncated": (size as usize) > max, "next_offset": offset + read }))
            }
            "fs.find_rollout" => {
                // Codex transcript for a running session: by conversation id, else the newest rollout for `cwd`
                // touched after `since`. Returns { path } or { path: null }.
                let codex_home = p.get("codex_home").and_then(|v| v.as_str()).map(util::expand_tilde).map(std::path::PathBuf::from)
                    .unwrap_or_else(|| util::home_dir().join(".codex"));
                let id = p.get("id").and_then(|v| v.as_str()).unwrap_or("");
                let cwd = p.get("cwd").and_then(|v| v.as_str()).unwrap_or("");
                let since = p.get("since").and_then(|v| v.as_u64()).unwrap_or(0);
                Ok(json!({ "path": agents::find_rollout(&codex_home, id, cwd, since) }))
            }
            "usage.refresh" => {
                // Re-reads what can be read on demand now (Codex rollouts); Claude readings arrive with its status line.
                // profile_ids: only these (the app's status bar); none = every profile (Refresh button).
                let ids: Option<Vec<String>> = p.get("profile_ids").and_then(|v| serde_json::from_value(v.clone()).ok());
                self.poll_codex_usage(ids.as_deref());
                let d = self.clone();
                std::thread::spawn(move || d.poll_claude_usage(ids.as_deref()));
                self.changed();
                Ok(json!({ "ok": true }))
            }
            "usage.report" => {
                // { session_id, rate_limits: { five_hour: {used_percentage, resets_at}, ... } }
                let sid = req("session_id")?;
                let profile_id = {
                    let st = self.state.lock().unwrap();
                    st.sessions.iter().find(|x| x.id == sid).and_then(|x| x.profile_id.clone())
                };
                let Some(profile_id) = profile_id else { return Ok(json!({ "ok": false })) };
                let mut readings = Vec::new();
                if let Some(obj) = p.get("rate_limits").and_then(|v| v.as_object()) {
                    for (window, w) in obj {
                        let Some(pct) = w.get("used_percentage").and_then(|v| v.as_f64()) else { continue };
                        readings.push((window.clone(), pct, w.get("resets_at").and_then(|v| v.as_i64())));
                    }
                }
                let n = self.store_usage(&profile_id, readings);
                Ok(json!({ "ok": true, "stored": n }))
            }
            "hook" => {
                let id = req("session_id")?;
                let event = req("event")?;
                let payload = p.get("payload").cloned().unwrap_or(Value::Null);
                self.on_hook(&id, &event, &payload);
                Ok(json!({ "ok": true }))
            }
            _ => bail!("unknown method {method}"),
        }
    }

    fn new_tab(&self, project_id: &str, session_id: &str) -> Tab {
        let mut st = self.state.lock().unwrap();
        let tab = Tab {
            id: util::short_id(),
            project_id: project_id.to_string(),
            sort: st.tabs.iter().map(|t| t.sort).max().unwrap_or(-1) + 1,
            layout: PaneNode::Leaf { session_id: session_id.to_string() },
            active_session_id: Some(session_id.to_string()),
        };
        st.tabs.push(tab.clone());
        let _ = self.store.lock().unwrap().put("tab", &tab.id, &tab);
        tab
    }

    fn create_session(self: &Arc<Self>, p: &Value) -> Result<Value> {
        let project_id = p.get("project_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("missing project_id"))?.to_string();
        let profile_id = p.get("profile_id").and_then(|v| v.as_str()).map(String::from);
        let command = p.get("command").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let placement: Placement = serde_json::from_value(p.get("placement").cloned().unwrap_or(json!("tab"))).unwrap_or(Placement::Tab);
        let worktree = p.get("worktree").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(util::expand_tilde);
        // Resume an earlier agent conversation (session history) instead of starting a new one.
        let resume = p.get("resume_agent_session_id").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from);
        if let Some(w) = &worktree {
            if !std::path::Path::new(w).is_dir() {
                bail!("worktree not found: {w}");
            }
        }
        let (cwd, kind, title) = {
            let st = self.state.lock().unwrap();
            let pr = st.projects.iter().find(|x| x.id == project_id).ok_or_else(|| anyhow!("no project {project_id}"))?;
            let cwd = p.get("cwd").and_then(|v| v.as_str()).map(util::expand_tilde).or_else(|| worktree.clone()).unwrap_or(pr.path.clone());
            if let Some(pid) = &profile_id {
                let prof = st.profiles.iter().find(|x| &x.id == pid).ok_or_else(|| anyhow!("no profile {pid}"))?;
                (cwd, SessionKind::Agent, prof.name.clone())
            } else if !command.is_empty() {
                (cwd, SessionKind::Action, p.get("title").and_then(|v| v.as_str()).unwrap_or(&command).to_string())
            } else {
                (cwd, SessionKind::Terminal, "Terminal".to_string())
            }
        };
        // Started from the chat screen: the first message names the session until the agent titles it.
        let title = match p.get("prompt").and_then(|v| v.as_str()).map(|t| t.trim()).filter(|t| !t.is_empty()) {
            Some(t) if kind == SessionKind::Agent => {
                let line = t.lines().next().unwrap_or(t);
                if line.chars().count() > 60 { format!("{}…", line.chars().take(59).collect::<String>()) } else { line.to_string() }
            }
            _ => title,
        };
        let now = util::now_secs();
        let session = Session {
            id: util::short_id(),
            project_id: project_id.clone(),
            kind,
            profile_id,
            title,
            custom_title: String::new(),
            cwd,
            state: SessionState::Interrupted,
            activity: Activity::Idle,
            unread: false,
            agent_session_id: resume.clone(),
            created_at: now,
            last_activity_at: now,
            exit_code: None,
            placement,
            command,
            worktree,
            transcript_path: None,
            agent_title: String::new(),
            extra_args: p.get("extra_args").and_then(|v| serde_json::from_value::<Vec<String>>(v.clone()).ok()).unwrap_or_default(),
            agent_app: None,
            reports_status: false,
            resume_agent: None,
        };
        {
            let mut st = self.state.lock().unwrap();
            st.sessions.push(session.clone());
        }
        self.persist_session(&session);

        // Place it: split an existing pane, or a new tab.
        let mut tab_id = None;
        if placement == Placement::Tab {
            let split_target = p.get("split_target").and_then(|v| v.as_str());
            let dir: SplitDir = serde_json::from_value(p.get("split_dir").cloned().unwrap_or(json!("right"))).unwrap_or(SplitDir::Right);
            if let Some(target) = split_target {
                let mut st = self.state.lock().unwrap();
                if let Some(t) = st.tabs.iter_mut().find(|t| t.layout.sessions().iter().any(|s| s == target)) {
                    let (mut layout, ok) = t.layout.clone().split(target, &session.id, dir);
                    if ok {
                        // The app sizes the panes (it knows their pixels): ratios for the new tree, pre-order.
                        if let Some(rs) = p.get("split_ratios").and_then(|v| v.as_array()) {
                            let rs: Vec<f64> = rs.iter().filter_map(|v| v.as_f64()).collect();
                            layout.set_ratios(&rs);
                        }
                        t.layout = layout;
                        t.active_session_id = Some(session.id.clone());
                        tab_id = Some(t.id.clone());
                        let t = t.clone();
                        let _ = self.store.lock().unwrap().put("tab", &t.id, &t);
                    }
                }
            }
            if tab_id.is_none() {
                tab_id = Some(self.new_tab(&project_id, &session.id).id);
            }
        }

        let cols = p.get("cols").and_then(|v| v.as_u64()).unwrap_or(120) as u16;
        let rows = p.get("rows").and_then(|v| v.as_u64()).unwrap_or(40) as u16;
        if let Some(prompt) = p.get("prompt").and_then(|v| v.as_str()).filter(|s| !s.trim().is_empty()) {
            self.prompts.lock().unwrap().insert(session.id.clone(), prompt.to_string());
        }
        self.spawning.lock().unwrap().insert(session.id.clone());
        let r = self.spawn_session_inner(&session.id, resume.is_some(), cols, rows);
        self.spawning.lock().unwrap().remove(&session.id);
        r?;
        let s = self.state.lock().unwrap().sessions.iter().find(|s| s.id == session.id).cloned();
        Ok(json!({ "session": s, "tab_id": tab_id }))
    }

    fn detach_from_tabs(&self, id: &str) {
        let mut st = self.state.lock().unwrap();
        let mut removed_tabs = Vec::new();
        let mut updated = Vec::new();
        for t in st.tabs.iter_mut() {
            if !t.layout.sessions().iter().any(|s| s == id) {
                continue;
            }
            match t.layout.clone().remove_balanced(id) {
                Some(l) => {
                    t.layout = l;
                    if t.active_session_id.as_deref() == Some(id) {
                        t.active_session_id = t.layout.sessions().first().cloned();
                    }
                    updated.push(t.clone());
                }
                None => removed_tabs.push(t.id.clone()),
            }
        }
        st.tabs.retain(|t| !removed_tabs.contains(&t.id));
        drop(st);
        let store = self.store.lock().unwrap();
        for t in updated {
            let _ = store.put("tab", &t.id, &t);
        }
        for t in removed_tabs {
            let _ = store.delete("tab", &t);
        }
    }

    fn remove_session(&self, id: &str) -> Result<()> {
        // Mark first so the monitor does not record an exit for it.
        self.state.lock().unwrap().sessions.retain(|s| s.id != id);
        self.store.lock().unwrap().delete("session", id)?;
        if holder_alive(&self.paths, id) {
            let _ = HolderClient::request(&self.paths, id, &HolderRequest::Kill);
        }
        self.detach_from_tabs(id);
        let _ = std::fs::remove_file(self.paths.holder_exit(id));
        Ok(())
    }

    fn delete_project(&self, id: &str) -> Result<()> {
        let sessions: Vec<String> = self.state.lock().unwrap().sessions.iter().filter(|s| s.project_id == id).map(|s| s.id.clone()).collect();
        for s in sessions {
            self.remove_session(&s)?;
        }
        let mut st = self.state.lock().unwrap();
        let tabs: Vec<String> = st.tabs.iter().filter(|t| t.project_id == id).map(|t| t.id.clone()).collect();
        st.tabs.retain(|t| t.project_id != id);
        st.projects.retain(|p| p.id != id);
        drop(st);
        let store = self.store.lock().unwrap();
        for t in tabs {
            store.delete("tab", &t)?;
        }
        store.delete("project", id)?;
        Ok(())
    }
}

#[cfg(test)]
mod turn_tests {
    use super::last_turn_record;
    use crate::util::parse_iso_millis;

    fn rec(ty: &str, content: &str, ts: &str) -> String {
        format!(r#"{{"type":"{ty}","timestamp":"{ts}","message":{{"role":"{ty}","content":{content}}}}}"#)
    }

    #[test]
    fn claude_session_records() {
        use super::claude_session_record as r;
        let rec = r#"{"pid":4242,"sessionId":"abc-1","cwd":"/x","startedAt":1793652278556,"kind":"interactive"}"#;
        assert_eq!(r(rec, 4242, 1793652278), Some("abc-1".into()));
        assert_eq!(r(rec, 4242, 1793652278 + 30), Some("abc-1".into()));
        assert_eq!(r(rec, 4242, 1793652278 + 3600), None); // the pid was reused by a later process
        assert_eq!(r(rec, 4243, 1793652278), None);
        assert_eq!(r(r#"{"pid":4242,"startedAt":1793652278556}"#, 4242, 1793652278), None);
        assert_eq!(r("not json", 4242, 0), None);
    }

    #[test]
    fn iso_times() {
        assert_eq!(parse_iso_millis("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_iso_millis("2026-11-03T16:47:52.541Z"), Some(1_793_724_472_541));
        assert_eq!(parse_iso_millis("2000-02-29T12:00:00.5Z"), Some(951_825_600_500));
        assert_eq!(parse_iso_millis("nope"), None);
    }

    #[test]
    fn esc_while_working_is_the_last_record() {
        let chunk = [
            rec("user", r#""fix the test""#, "2026-11-03T10:00:00.000Z"),
            rec("assistant", r#"[{"type":"text","text":"Looking"}]"#, "2026-11-03T10:00:01.000Z"),
            rec("user", r#"[{"type":"text","text":"[Request interrupted by user]"}]"#, "2026-11-03T10:00:02.000Z"),
        ]
        .join("\n");
        assert_eq!(last_turn_record(&chunk), Some((true, parse_iso_millis("2026-11-03T10:00:02.000Z"))));
    }

    #[test]
    fn esc_at_a_permission_prompt() {
        let chunk = [
            rec("assistant", r#"[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]"#, "2026-11-03T10:00:01.000Z"),
            rec("user", r#"[{"type":"tool_result","tool_use_id":"t1","content":"The user doesn't want to proceed","is_error":true}]"#, "2026-11-03T10:00:05.000Z"),
            rec("user", r#"[{"type":"text","text":"[Request interrupted by user for tool use]"}]"#, "2026-11-03T10:00:05.001Z"),
        ]
        .join("\n");
        assert_eq!(last_turn_record(&chunk).map(|r| r.0), Some(true));
    }

    #[test]
    fn a_new_prompt_after_the_interrupt_wins() {
        let chunk = [
            rec("user", r#"[{"type":"text","text":"[Request interrupted by user]"}]"#, "2026-11-03T10:00:02.000Z"),
            rec("user", r#""try again""#, "2026-11-03T10:00:09.000Z"),
        ]
        .join("\n");
        assert_eq!(last_turn_record(&chunk).map(|r| r.0), Some(false));
    }

    #[test]
    fn titles_sidechains_and_meta_are_not_turns() {
        let chunk = [
            rec("user", r#"[{"type":"text","text":"[Request interrupted by user]"}]"#, "2026-11-03T10:00:02.000Z"),
            r#"{"type":"ai-title","aiTitle":"Fix test"}"#.to_string(),
            r#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sub"}]}}"#.to_string(),
            r#"{"type":"user","isMeta":true,"message":{"content":"<command-name>/model</command-name>"}}"#.to_string(),
        ]
        .join("\n");
        assert_eq!(last_turn_record(&chunk).map(|r| r.0), Some(true));
        assert_eq!(last_turn_record(r#"{"type":"ai-title","aiTitle":"x"}"#), None);
    }

    #[test]
    fn quoting_the_marker_mid_message_is_not_an_interrupt() {
        let chunk = rec("user", r#""why did I see [Request interrupted by user] earlier?""#, "2026-11-03T10:00:02.000Z");
        assert_eq!(last_turn_record(&chunk).map(|r| r.0), Some(false));
    }
}
