//! End-to-end tests: real daemon, real holders, real PTYs. The screen is
//! verified as text through the holder's headless VT.

use ade_proto::{Frame, Hello, Kind, Role};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_ade");

struct Env {
    home: PathBuf,
    daemon: Option<Child>,
    project_dir: PathBuf,
}

impl Env {
    fn new() -> Env {
        // Short path: Unix socket paths are limited to ~104 bytes on macOS.
        static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let tag = format!("{:x}{n}{:x}", std::process::id(), rand_u16());
        let home = PathBuf::from(format!("/tmp/adet-{tag}"));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let project_dir = home.join("proj");
        std::fs::create_dir_all(&project_dir).unwrap();
        let mut e = Env { home, daemon: None, project_dir };
        e.start_daemon();
        e
    }

    fn start_daemon(&mut self) {
        let child = Command::new(BIN)
            .arg("daemon")
            .env("ADE_HOME", &self.home)
            .env("CLAUDE_CODE_CHILD_SESSION", "1")
            .env("CLAUDECODE", "1")
            .env("CLAUDE_CONFIG_DIR", "/should/not/leak")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        self.daemon = Some(child);
        wait_until(Duration::from_secs(5), || UnixStream::connect(self.home.join("run/daemon.sock")).is_ok());
    }

    fn kill_daemon(&mut self) {
        if let Some(mut c) = self.daemon.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        // A killed daemon leaves its socket file behind; that is expected.
    }

    fn call(&self, method: &str, params: Value) -> Value {
        self.try_call(method, params).unwrap_or_else(|e| panic!("{method}: {e}"))
    }

    fn try_call(&self, method: &str, params: Value) -> Result<Value, String> {
        let mut s = UnixStream::connect(self.home.join("run/daemon.sock")).map_err(|e| e.to_string())?;
        s.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let line = serde_json::to_string(&json!({ "id": 1, "method": method, "params": params })).unwrap();
        s.write_all(line.as_bytes()).unwrap();
        s.write_all(b"\n").unwrap();
        let mut r = BufReader::new(s);
        loop {
            let mut buf = String::new();
            r.read_line(&mut buf).map_err(|e| e.to_string())?;
            let v: Value = serde_json::from_str(&buf).map_err(|e| format!("{e}: {buf}"))?;
            if v.get("event").is_some() {
                continue;
            }
            if let Some(e) = v.get("error") {
                return Err(e.to_string());
            }
            return Ok(v["result"].clone());
        }
    }

    fn workspace(&self) -> String {
        self.call("state.get", json!({}))["workspaces"][0]["id"].as_str().unwrap().to_string()
    }

    fn project(&self) -> String {
        let ws = self.workspace();
        self.call("project.create", json!({ "workspace_id": ws, "path": self.project_dir }))["id"].as_str().unwrap().to_string()
    }

    fn session(&self, id: &str) -> Value {
        let st = self.call("state.get", json!({}));
        st["sessions"].as_array().unwrap().iter().find(|s| s["id"] == id).cloned().unwrap_or(Value::Null)
    }

    fn screen(&self, id: &str) -> String {
        self.call("session.screen_text", json!({ "id": id }))["text"].as_str().unwrap_or("").to_string()
    }

    fn input(&self, id: &str, data: &str) {
        self.call("session.input", json!({ "id": id, "data": data }));
    }

    fn wait_screen(&self, id: &str, needle: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let s = self.screen(id);
            if s.contains(needle) {
                return s;
            }
            if Instant::now() > deadline {
                panic!("timeout waiting for {needle:?} on screen:\n{s}");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn holder_alive(&self, id: &str) -> bool {
        UnixStream::connect(self.home.join(format!("run/{id}.sock"))).is_ok()
    }

    fn holder_pids(&self, id: &str) -> (i32, Option<i32>) {
        let info: Value = serde_json::from_slice(&std::fs::read(self.home.join(format!("run/{id}.json"))).unwrap()).unwrap();
        (info["pid"].as_i64().unwrap() as i32, info["child_pid"].as_i64().map(|p| p as i32))
    }

    /// Simulates a reboot for one session: holder and child vanish without an exit record.
    fn hard_kill_holder(&self, id: &str) {
        let (pid, child) = self.holder_pids(id);
        unsafe {
            if let Some(c) = child {
                libc::kill(-c, libc::SIGKILL);
                libc::kill(c, libc::SIGKILL);
            }
            libc::kill(pid, libc::SIGKILL);
        }
        wait_until(Duration::from_secs(5), || !self.holder_alive(id));
        let _ = std::fs::remove_file(self.home.join(format!("run/{id}.exit")));
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        self.kill_daemon();
        // Kill every holder we started.
        if let Ok(rd) = std::fs::read_dir(self.home.join("run")) {
            for e in rd.flatten() {
                let p = e.path();
                if p.extension().and_then(|x| x.to_str()) == Some("json") {
                    if let Ok(v) = serde_json::from_slice::<Value>(&std::fs::read(&p).unwrap_or_default()) {
                        unsafe {
                            if let Some(c) = v["child_pid"].as_i64() {
                                libc::kill(-(c as i32), libc::SIGKILL);
                            }
                            if let Some(h) = v["pid"].as_i64() {
                                libc::kill(h as i32, libc::SIGKILL);
                            }
                        }
                    }
                }
            }
        }
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

fn rand_u16() -> u16 {
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().subsec_nanos();
    (t ^ (t >> 16)) as u16
}

fn wait_until(timeout: Duration, mut f: impl FnMut() -> bool) {
    let deadline = Instant::now() + timeout;
    while !f() {
        if Instant::now() > deadline {
            panic!("condition not met within {timeout:?}");
        }
        std::thread::sleep(Duration::from_millis(30));
    }
}

/// Attaches like `ade attach` does, returning the stream and the snapshot bytes.
fn attach(home: &Path, id: &str, cols: u16, rows: u16) -> (UnixStream, Vec<u8>) {
    let mut s = UnixStream::connect(home.join(format!("run/{id}.sock"))).unwrap();
    Frame::json(Kind::Hello, &Hello { version: 1, role: Role::Attach, cols, rows }).write_to(&mut s).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let f = Frame::read_from(&mut s).unwrap().unwrap();
    assert_eq!(f.kind, Kind::Snapshot);
    (s, f.payload)
}

fn create_terminal(e: &Env, project: &str) -> String {
    let r = e.call("session.create", json!({ "project_id": project, "cols": 80, "rows": 24 }));
    r["session"]["id"].as_str().unwrap().to_string()
}

/// A shell prompt we can recognise, independent of the user's zsh config.
fn plain_shell(e: &Env, project: &str) -> String {
    let id = create_terminal(e, project);
    e.input(&id, "exec /bin/sh\r");
    std::thread::sleep(Duration::from_millis(300));
    e.input(&id, "PS1='ade$ '; echo READY$((40+2))\r");
    e.wait_screen(&id, "READY42");
    e.input(&id, "echo C$((1+1)); clear; echo CLEARED$((2+2))\r");
    e.wait_screen(&id, "CLEARED4");
    id
}

#[test]
fn terminal_session_runs_and_screen_is_readable() {
    let e = Env::new();
    let p = e.project();
    let id = plain_shell(&e, &p);
    e.input(&id, "echo hello-$((40+2))\r");
    e.wait_screen(&id, "hello-42");
    let s = e.session(&id);
    assert_eq!(s["state"], "running");
    assert_eq!(s["kind"], "terminal");
}

#[test]
fn turkish_text_roundtrips() {
    let e = Env::new();
    let p = e.project();
    let id = plain_shell(&e, &p);
    e.input(&id, "printf 'çğıöşü ÇĞİÖŞÜ\\n'\r");
    e.wait_screen(&id, "çğıöşü ÇĞİÖŞÜ");
}

#[test]
fn ui_detach_and_reattach_restores_screen() {
    let e = Env::new();
    let p = e.project();
    let id = plain_shell(&e, &p);
    e.input(&id, "printf '\\033[1;31mRED\\033[0m line\\n'; echo sec$((1))ond\r");
    e.wait_screen(&id, "sec1ond");

    // First "UI" attaches and gets a snapshot equal to the holder's screen.
    let (s1, snap1) = attach(&e.home, &id, 80, 24);
    let mut v = vt100::Parser::new(24, 80, 0);
    v.process(&snap1);
    assert_eq!(v.screen().contents(), e.screen(&id));
    drop(s1); // UI quits

    // Session keeps running without any client.
    e.input(&id, "echo while-$((0))detached\r");
    e.wait_screen(&id, "while-0detached");

    // Second "UI" sees everything, colours included.
    let (_s2, snap2) = attach(&e.home, &id, 80, 24);
    let mut v2 = vt100::Parser::new(24, 80, 0);
    v2.process(&snap2);
    let text = v2.screen().contents();
    assert!(text.contains("while-0detached"), "{text}");
    let rows: Vec<String> = v2.screen().rows(0, 80).collect();
    let red_row = rows.iter().position(|r| r.starts_with("RED")).unwrap_or_else(|| panic!("RED row: {rows:#?}")) as u16;
    assert_eq!(v2.screen().cell(red_row, 0).unwrap().fgcolor(), vt100::Color::Idx(1));
    assert!(v2.screen().cell(red_row, 0).unwrap().bold());
}

#[test]
fn live_output_streams_to_attached_client() {
    let e = Env::new();
    let p = e.project();
    let id = plain_shell(&e, &p);
    let (mut s, snap) = attach(&e.home, &id, 80, 24);
    let mut v = vt100::Parser::new(24, 80, 0);
    v.process(&snap);
    Frame::new(Kind::Input, b"echo streamed-$((6*7))\r".to_vec()).write_to(&mut s).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !v.screen().contents().contains("streamed-42") {
        assert!(Instant::now() < deadline, "no streamed output:\n{}", v.screen().contents());
        if let Ok(Some(f)) = Frame::read_from(&mut s) {
            if f.kind == Kind::Output {
                v.process(&f.payload);
            }
        }
    }
}

#[test]
fn resize_reaches_the_program() {
    let e = Env::new();
    let p = e.project();
    let id = plain_shell(&e, &p);
    let (mut s, _) = attach(&e.home, &id, 80, 24);
    Frame::resize(101, 33).write_to(&mut s).unwrap();
    std::thread::sleep(Duration::from_millis(200));
    e.input(&id, "clear; stty size\r");
    e.wait_screen(&id, "33 101");
    let info = e.call("session.info", json!({ "id": id }));
    assert_eq!(info["cols"], 101);
    assert_eq!(info["rows"], 33);
}

#[test]
fn vim_alt_screen_survives_reattach() {
    let e = Env::new();
    let p = e.project();
    let id = plain_shell(&e, &p);
    e.input(&id, "vim -u NONE -N\r");
    std::thread::sleep(Duration::from_millis(500));
    e.input(&id, "ihello from vim\x1b");
    e.wait_screen(&id, "hello from vim");
    let (mut s, snap) = attach(&e.home, &id, 80, 24);
    let mut v = vt100::Parser::new(24, 80, 0);
    v.process(&snap);
    assert!(v.screen().alternate_screen(), "vim runs in the alternate screen: {:?}", e.call("session.screen_text", json!({ "id": id })));
    assert_eq!(v.screen().contents(), e.screen(&id));
    e.input(&id, ":q!\r");
    e.wait_screen(&id, "ade$");
    // A client that attached while vim was up must see the shell again after vim exits.
    let deadline = Instant::now() + Duration::from_secs(10);
    while v.screen().alternate_screen() || v.screen().contents() != e.screen(&id) {
        assert!(Instant::now() < deadline, "main screen not restored:\n{}", v.screen().contents());
        if let Ok(Some(f)) = Frame::read_from(&mut s) {
            if f.kind == Kind::Output {
                v.process(&f.payload);
            }
        }
    }
    assert!(v.screen().contents().contains("CLEARED4"), "main screen content is back");
}

#[test]
fn sessions_survive_daemon_death() {
    let mut e = Env::new();
    let p = e.project();
    let id = plain_shell(&e, &p);
    e.input(&id, "echo before-$((1))crash\r");
    e.wait_screen(&id, "before-1crash");

    e.kill_daemon();
    assert!(e.holder_alive(&id), "holder must outlive the daemon");
    e.start_daemon();

    let s = e.session(&id);
    assert_eq!(s["state"], "running");
    let text = e.wait_screen(&id, "before-1crash");
    assert!(text.contains("ade$"));
    e.input(&id, "echo after-$((1))crash\r");
    e.wait_screen(&id, "after-1crash");
}

#[test]
fn terminal_restored_as_fresh_shell_after_reboot() {
    let mut e = Env::new();
    let p = e.project();
    let id = create_terminal(&e, &p);
    std::thread::sleep(Duration::from_millis(300));
    e.kill_daemon();
    e.hard_kill_holder(&id);
    e.start_daemon();
    // The daemon brings the session back on its own.
    wait_until(Duration::from_secs(10), || e.holder_alive(&id));
    wait_until(Duration::from_secs(5), || e.session(&id)["state"] == "running");
    e.input(&id, "pwd\r");
    e.wait_screen(&id, "proj");
}

fn fake_agent(e: &Env) -> PathBuf {
    let script = e.home.join("fake-agent.sh");
    std::fs::write(&script, "#!/bin/sh\necho \"FAKE-ARGS: $*\"\necho \"CFG=$CLAUDE_CONFIG_DIR\"\nexec cat\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    script
}

#[test]
fn claude_profile_uses_session_id_then_resume() {
    let mut e = Env::new();
    let p = e.project();
    let script = fake_agent(&e);
    let cfg = e.home.join("claude-cfg");
    let prof = e.call(
        "profile.create",
        json!({ "name": "Claude (work)", "kind": "claude", "command": script, "args": ["--model", "opus", "--resume", "zzz"],
                "env": { "CLAUDE_CONFIG_DIR": cfg }, "via_login_shell": false }),
    );
    let r = e.call("session.create", json!({ "project_id": p, "profile_id": prof["id"] }));
    let id = r["session"]["id"].as_str().unwrap().to_string();
    let agent_id = r["session"]["agent_session_id"].as_str().unwrap().to_string();
    let text = e.wait_screen(&id, "FAKE-ARGS");
    assert!(text.contains(&format!("--session-id {agent_id}")), "{text}");
    assert!(text.contains("--model opus"), "{text}");
    assert!(!text.contains("zzz"), "user resume flags are stripped: {text}");
    assert!(text.contains("--settings"), "{text}");
    assert!(text.contains(&format!("CFG={}", cfg.display())), "{text}");

    // Claude wrote a transcript; then the machine "reboots".
    let proj_dir = cfg.join("projects/-tmp-proj");
    std::fs::create_dir_all(&proj_dir).unwrap();
    std::fs::write(proj_dir.join(format!("{agent_id}.jsonl")), "{}\n").unwrap();
    e.kill_daemon();
    e.hard_kill_holder(&id);
    e.start_daemon();
    wait_until(Duration::from_secs(10), || e.holder_alive(&id));
    let text = e.wait_screen(&id, "FAKE-ARGS");
    assert!(text.contains(&format!("--resume {agent_id}")), "{text}");
    assert_eq!(e.session(&id)["agent_session_id"], agent_id.as_str());
}

#[test]
fn session_start_hook_updates_agent_id_and_activity_flows() {
    let e = Env::new();
    let p = e.project();
    let script = fake_agent(&e);
    let prof = e.call("profile.create", json!({ "name": "c", "kind": "claude", "command": script, "via_login_shell": false }));
    let r = e.call("session.create", json!({ "project_id": p, "profile_id": prof["id"] }));
    let id = r["session"]["id"].as_str().unwrap().to_string();

    let hook = |event: &str, payload: Value| {
        let mut c = Command::new(BIN)
            .args(["hook", event])
            .env("ADE_HOME", &e.home)
            .env("ADE_SESSION_ID", &id)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        c.stdin.take().unwrap().write_all(payload.to_string().as_bytes()).unwrap();
        let out = c.wait_with_output().unwrap();
        assert!(out.status.success());
        assert!(out.stdout.is_empty(), "hooks must stay silent");
    };
    hook("SessionStart", json!({ "session_id": "new-conv-after-clear", "source": "clear" }));
    assert_eq!(e.session(&id)["agent_session_id"], "new-conv-after-clear");
    hook("UserPromptSubmit", json!({}));
    assert_eq!(e.session(&id)["activity"], "working");
    hook("Notification", json!({ "notification_type": "permission_prompt", "message": "Claude needs your permission" }));
    assert_eq!(e.session(&id)["activity"], "needs_input");
    assert_eq!(e.session(&id)["unread"], true);
    hook("PreToolUse", json!({}));
    assert_eq!(e.session(&id)["activity"], "working");
    hook("Stop", json!({}));
    assert_eq!(e.session(&id)["activity"], "done");
    e.call("session.mark_read", json!({ "id": id }));
    let s = e.session(&id);
    assert_eq!(s["unread"], false);
    assert_eq!(s["activity"], "idle");
}

#[test]
fn osc_program_status_and_notifications() {
    let e = Env::new();
    let p = e.project();
    let id = plain_shell(&e, &p);
    // Subscribe to events.
    let mut sub = UnixStream::connect(e.home.join("run/daemon.sock")).unwrap();
    sub.write_all(b"{\"id\":1,\"method\":\"subscribe\",\"params\":{}}\n").unwrap();
    sub.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut r = BufReader::new(sub);

    e.input(&id, "printf '\\033]7501;state=working\\033\\\\'\r");
    wait_until(Duration::from_secs(5), || e.session(&id)["activity"] == "working");
    e.input(&id, "printf '\\033]7501;state=done\\033\\\\'\r");
    wait_until(Duration::from_secs(5), || e.session(&id)["activity"] == "done");
    e.input(&id, "printf '\\033]777;notify;Build;all green\\007'\r");

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut kinds = Vec::new();
    while Instant::now() < deadline && !(kinds.contains(&"done".to_string()) && kinds.contains(&"program".to_string())) {
        let mut line = String::new();
        if r.read_line(&mut line).is_err() {
            break;
        }
        let v: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
        if v["event"] == "notify" {
            kinds.push(v["data"]["kind"].as_str().unwrap_or("").to_string());
            if v["data"]["kind"] == "program" {
                assert_eq!(v["data"]["title"], "Build");
                assert_eq!(v["data"]["body"], "all green");
            }
        }
    }
    assert!(kinds.contains(&"done".to_string()), "{kinds:?}");
    assert!(kinds.contains(&"program".to_string()), "{kinds:?}");
}

#[test]
fn title_from_osc() {
    let e = Env::new();
    let p = e.project();
    let id = plain_shell(&e, &p);
    e.input(&id, "printf '\\033]0;✳ Refactor auth\\007'\r");
    wait_until(Duration::from_secs(5), || e.session(&id)["title"] == "Refactor auth");
}

#[test]
fn stop_restart_remove_and_layout() {
    let e = Env::new();
    let p = e.project();
    let a = create_terminal(&e, &p);
    let r = e.call("session.create", json!({ "project_id": p, "split_target": a, "split_dir": "right" }));
    let b = r["session"]["id"].as_str().unwrap().to_string();
    let st = e.call("state.get", json!({}));
    let tabs = st["tabs"].as_array().unwrap();
    assert_eq!(tabs.len(), 1, "split stays in the same tab");
    assert_eq!(tabs[0]["layout"]["type"], "split");

    e.call("session.stop", json!({ "id": a }));
    wait_until(Duration::from_secs(6), || !e.holder_alive(&a));
    assert_eq!(e.session(&a)["state"], "stopped", "stopped stays stopped");
    assert!(e.try_call("session.ensure", json!({ "id": a })).is_err(), "attach must not revive a stopped session");

    e.call("session.restart", json!({ "id": a }));
    assert!(e.holder_alive(&a));
    assert_eq!(e.session(&a)["state"], "running");

    e.call("session.remove", json!({ "id": b }));
    wait_until(Duration::from_secs(6), || !e.holder_alive(&b));
    let st = e.call("state.get", json!({}));
    assert_eq!(st["tabs"][0]["layout"]["type"], "leaf");
    assert!(st["sessions"].as_array().unwrap().iter().all(|s| s["id"] != b.as_str()));
}

#[test]
fn shell_exit_marks_session_exited() {
    let e = Env::new();
    let p = e.project();
    let id = plain_shell(&e, &p);
    e.input(&id, "exit 3\r");
    wait_until(Duration::from_secs(5), || e.session(&id)["state"] == "exited");
    assert_eq!(e.session(&id)["exit_code"], 3);
}

#[test]
fn settings_resolve_by_scope() {
    let e = Env::new();
    let p = e.project();
    let ws = e.workspace();
    e.call("settings.set", json!({ "scope": "global", "key": "x", "value": 1 }));
    e.call("settings.set", json!({ "scope": format!("workspace:{ws}"), "key": "x", "value": 2 }));
    let st = e.call("state.get", json!({}));
    assert_eq!(st["settings"].as_array().unwrap().len(), 2);
    e.call("settings.set", json!({ "scope": "global", "key": "x", "value": null }));
    let st = e.call("state.get", json!({}));
    assert_eq!(st["settings"].as_array().unwrap().len(), 1);
    let _ = p;
}

#[test]
fn ade_attach_binary_proxies_a_pty() {
    // Run the real `ade attach` inside a PTY (as a libghostty surface would).
    let e = Env::new();
    let p = e.project();
    let id = plain_shell(&e, &p);
    e.input(&id, "echo attached-$((1))ok\r");
    e.wait_screen(&id, "attached-1ok");

    // Use a second ADE session as the "outer terminal" that runs `ade attach`.
    let outer = create_terminal(&e, &p);
    e.input(&outer, &format!("exec env ADE_HOME={} {} attach {}\r", e.home.display(), BIN, id));
    e.wait_screen(&outer, "attached-1ok");
    e.input(&outer, "echo via-$((1))proxy\r");
    e.wait_screen(&id, "via-1proxy");
}

#[test]
fn enclosing_agent_env_does_not_leak_into_sessions() {
    let e = Env::new();
    let p = e.project();
    let id = plain_shell(&e, &p);
    e.input(&id, "echo LEAK=${CLAUDECODE:-none}/${CLAUDE_CODE_CHILD_SESSION:-none}/${CLAUDE_CONFIG_DIR:-none}/$((1))\r");
    let text = e.wait_screen(&id, "/1");
    assert!(text.contains("LEAK=none/none/none/1"), "{text}");
}

#[test]
fn dock_action_runs_command_once_and_restores_as_shell() {
    let mut e = Env::new();
    let p = e.project();
    let marker = e.home.join("ran-count");
    let cmd = format!("echo run >> {} && echo ACTION-$((20+1))", marker.display());
    let r = e.call("session.create", json!({ "project_id": p, "command": cmd, "title": "Test", "placement": "dock" }));
    let id = r["session"]["id"].as_str().unwrap().to_string();
    assert_eq!(r["session"]["kind"], "action");
    assert_eq!(r["session"]["placement"], "dock");
    assert!(r["tab_id"].is_null(), "dock sessions are not in tabs");
    e.wait_screen(&id, "ACTION-21");
    e.kill_daemon();
    e.hard_kill_holder(&id);
    e.start_daemon();
    wait_until(Duration::from_secs(10), || e.holder_alive(&id));
    std::thread::sleep(Duration::from_millis(800));
    let runs = std::fs::read_to_string(&marker).unwrap();
    assert_eq!(runs.lines().count(), 1, "restore must not re-run the action");
}

#[test]
fn statusline_reports_usage_and_passes_through_user_statusline() {
    let e = Env::new();
    let p = e.project();
    let script = fake_agent(&e);
    let prof = e.call("profile.create", json!({ "name": "c", "kind": "generic", "command": script, "via_login_shell": false }));
    let r = e.call("session.create", json!({ "project_id": p, "profile_id": prof["id"] }));
    let id = r["session"]["id"].as_str().unwrap().to_string();

    // The hook settings we inject carry our status line.
    let settings: Value = serde_json::from_str(&std::fs::read_to_string(e.home.join("agent/claude-settings.json")).unwrap()).unwrap();
    assert!(settings["statusLine"]["command"].as_str().unwrap().ends_with("statusline"), "{settings}");

    // The user's own status line lives in their config dir and must keep working.
    let cfg = e.home.join("user-cfg");
    std::fs::create_dir_all(&cfg).unwrap();
    std::fs::write(cfg.join("settings.json"), r#"{"statusLine":{"type":"command","command":"python3 -c 'import sys,json; print(\"USERLINE \" + json.load(sys.stdin)[\"model\"][\"display_name\"])'"}}"#).unwrap();
    let payload = json!({
        "model": { "display_name": "Opus" },
        "workspace": { "current_dir": "/nonexistent" },
        "rate_limits": { "five_hour": { "used_percentage": 42.5, "resets_at": 1900000000 }, "seven_day": { "used_percentage": 18, "resets_at": 1900500000 } }
    });
    let run = |cfg: &Path| {
        let mut c = std::process::Command::new(BIN)
            .arg("statusline")
            .env("ADE_HOME", &e.home)
            .env("ADE_SESSION_ID", &id)
            .env("CLAUDE_CONFIG_DIR", cfg)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        use std::io::Write;
        c.stdin.take().unwrap().write_all(payload.to_string().as_bytes()).unwrap();
        String::from_utf8(c.wait_with_output().unwrap().stdout).unwrap()
    };
    let out = run(&cfg);
    assert_eq!(out.trim(), "USERLINE Opus");
    let st = e.call("state.get", json!({}));
    let usage = st["usage"].as_array().unwrap();
    assert_eq!(usage.len(), 2, "{st}");
    let five = usage.iter().find(|u| u["window"] == "five_hour").unwrap();
    assert_eq!(five["profile_id"], prof["id"]);
    assert_eq!(five["used_percent"], 42.5);
    assert_eq!(five["resets_at"], 1900000000);

    // No user status line: a short default line.
    let empty = e.home.join("empty-cfg");
    std::fs::create_dir_all(&empty).unwrap();
    assert_eq!(run(&empty).trim(), "Opus");
}
