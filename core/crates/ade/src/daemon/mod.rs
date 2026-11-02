//! The ADE daemon: owns the catalog (workspaces, projects, sessions, tabs,
//! profiles, settings), spawns and watches session holders, restores sessions
//! after crashes/reboots, turns hook/OSC signals into activity + notifications,
//! and serves the control API.

pub mod agents;
pub mod store;

use crate::holder::HolderClient;
use crate::util;
use ade_proto::control::*;
use ade_proto::{Frame, HolderEvent, HolderRequest, Kind, Paths, Role};
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
    cmd_started: Mutex<HashMap<String, Instant>>,
    dirty: Sender<()>,
    login_path: Mutex<Option<String>>,
    aliases: Mutex<Vec<(String, String)>>,
}

pub fn run(paths: Paths) -> Result<()> {
    util::ensure_dir_0700(&paths.home)?;
    util::ensure_dir_0700(&paths.run_dir())?;
    util::ensure_dir_0700(&paths.logs_dir())?;
    let sock = paths.daemon_socket();
    if UnixStream::connect(&sock).is_ok() {
        bail!("daemon already running");
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
        cmd_started: Mutex::new(HashMap::new()),
        dirty: dirty_tx,
        login_path: Mutex::new(None),
        aliases: Mutex::new(Vec::new()),
    });

    // Bind under a private name, then atomically publish (never unlink a live socket).
    let tmp = paths.run_dir().join(format!("d{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let listener = UnixListener::bind(&tmp).with_context(|| format!("bind {}", tmp.display()))?;
    util::set_mode_0600(&tmp);
    std::fs::rename(&tmp, &sock)?;
    eprintln!("[ade-daemon] pid {} listening on {}", std::process::id(), sock.display());

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
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_secs(60));
            d.poll_codex_usage();
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
        let _ = self.store.lock().unwrap().put("session", &s.id, s);
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
                        let exited = std::fs::read(self.paths.holder_exit(&id)).ok().and_then(|b| serde_json::from_slice::<ade_proto::ExitInfo>(&b).ok());
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
        let mut spec = agents::build_launch(&self.paths, &session, profile.as_ref(), restoring, &aliases);
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
        cmd.env("ADE_HOME", &self.paths.home).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(log);
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
                            exited = f.parse_json::<ade_proto::ExitInfo>().ok();
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

    fn on_holder_gone(self: &Arc<Self>, id: &str, exited: Option<ade_proto::ExitInfo>) {
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

    /// Every minute: Codex rate limits from its rollout files, for profiles with a running session.
    fn poll_codex_usage(&self) {
        let profiles: Vec<Profile> = {
            let st = self.state.lock().unwrap();
            st.profiles
                .iter()
                .filter(|p| p.kind == AgentKind::Codex && st.sessions.iter().any(|s| s.profile_id.as_deref() == Some(&p.id) && s.state == SessionState::Running))
                .cloned()
                .collect()
        };
        for p in profiles {
            let r = agents::codex_rate_limits(&p);
            self.store_usage(&p.id, r);
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
            if matches!(new, Activity::Done | Activity::NeedsInput | Activity::Error) {
                s.unread = true;
            }
            let copy = s.clone();
            let project = st.projects.iter().find(|p| p.id == copy.project_id).map(|p| p.name.clone()).unwrap_or_default();
            let profile = copy.profile_id.as_ref().and_then(|pid| st.profiles.iter().find(|p| &p.id == pid)).map(|p| p.name.clone());
            drop(st);
            self.persist_session(&copy);
            (copy, project, profile)
        };
        let (s, project, profile) = info;
        let name = if !s.custom_title.is_empty() { s.custom_title.clone() } else if !s.title.is_empty() { s.title.clone() } else { profile.clone().unwrap_or("Session".into()) };
        let agent = profile.unwrap_or_else(|| "Terminal".into());
        let note = match new {
            Activity::Done => Some(("done", format!("{agent} finished"), format!("{project} · {name}"))),
            Activity::NeedsInput => Some(("needs_input", format!("{agent} needs your input"), format!("{project} · {name}"))),
            Activity::Error => Some(("error", format!("{agent} hit an error"), format!("{project} · {name}"))),
            _ => None,
        };
        if let Some((kind, title, body)) = note {
            if self.notifications_enabled(&s.project_id, kind) {
                self.emit("notify", serde_json::to_value(Notification { session_id: s.id.clone(), project_id: s.project_id.clone(), kind: kind.into(), title, body }).unwrap());
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
            HolderEvent::ProgramStatus { state, .. } => {
                let a = match state.as_str() {
                    "working" => Activity::Working,
                    "blocked" => Activity::NeedsInput,
                    "done" => Activity::Done,
                    "error" => Activity::Error,
                    _ => Activity::Idle,
                };
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
                    self.emit("notify", serde_json::to_value(Notification { session_id: id.into(), project_id: pid, kind: "program".into(), title, body }).unwrap());
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
                        self.emit(
                            "notify",
                            serde_json::to_value(Notification {
                                session_id: id.into(),
                                project_id: pid,
                                kind: "command_done".into(),
                                title: if ok { "Command finished".into() } else { format!("Command failed (exit {})", exit_code.unwrap_or(-1)) },
                                body: format!("{title} · {secs}s"),
                            })
                            .unwrap(),
                        );
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
        }
    }

    fn on_hook(self: &Arc<Self>, id: &str, event: &str, payload: &Value) {
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
        match event {
            "SessionStart" => {
                if let Some(sid) = payload.get("session_id").and_then(|v| v.as_str()) {
                    let sid = sid.to_string();
                    let changed = self.with_session(id, |s| {
                        if s.agent_session_id.as_deref() != Some(&sid) {
                            s.agent_session_id = Some(sid.clone());
                            true
                        } else {
                            false
                        }
                    });
                    if changed == Some(true) {
                        self.changed();
                    }
                }
                self.set_activity(id, Activity::Idle);
            }
            "UserPromptSubmit" | "PreToolUse" => self.set_activity(id, Activity::Working),
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
            "hello" => Ok(json!({ "version": ade_proto::PROTOCOL_VERSION, "pid": std::process::id(), "home": self.paths.home })),
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
                const ALLOWED: &[&str] = &["status", "diff", "log", "show", "ls-files", "rev-parse", "worktree", "add", "commit", "push", "branch"];
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
            agent_session_id: None,
            created_at: now,
            last_activity_at: now,
            exit_code: None,
            placement,
            command,
            worktree,
            transcript_path: None,
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
                    let (layout, ok) = t.layout.clone().split(target, &session.id, dir);
                    if ok {
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
        self.spawning.lock().unwrap().insert(session.id.clone());
        let r = self.spawn_session_inner(&session.id, false, cols, rows);
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
            match t.layout.clone().remove(id) {
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
