//! Blocking control-plane client (NDJSON over the daemon socket).

use ade_proto::Paths;
use ade_proto::control::{Event, Response};
use anyhow::{Context, Result, anyhow};
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

pub struct Control {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next_id: u64,
    pub pending_events: Vec<Event>,
}

pub const LAUNCH_LABEL: &str = "dev.octomux.daemon";
/// The launchd label used before the rename; `install-agent` replaces it.
pub const LEGACY_LAUNCH_LABEL: &str = "dev.ade-dev.daemon";

impl Control {
    pub fn connect(paths: &Paths) -> Result<Control> {
        let s = UnixStream::connect(paths.daemon_socket()).context("connect daemon")?;
        Ok(Control { reader: BufReader::new(s.try_clone()?), writer: s, next_id: 1, pending_events: Vec::new() })
    }

    /// Connects, starting the daemon if needed (launchd job if installed, else a detached process).
    pub fn connect_or_spawn(paths: &Paths) -> Result<Control> {
        if let Ok(c) = Control::connect(paths) {
            return Ok(c);
        }
        start_daemon(paths)?;
        let deadline = Instant::now() + Duration::from_secs(8);
        loop {
            if let Ok(c) = Control::connect(paths) {
                return Ok(c);
            }
            if Instant::now() > deadline {
                return Err(anyhow!("daemon did not start"));
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    pub fn set_timeout(&self, d: Option<Duration>) {
        let _ = self.reader.get_ref().set_read_timeout(d);
    }

    pub fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id;
        self.next_id += 1;
        let line = serde_json::to_string(&serde_json::json!({ "id": id, "method": method, "params": params }))?;
        self.writer.write_all(line.as_bytes())?;
        self.writer.write_all(b"\n")?;
        loop {
            let mut buf = String::new();
            if self.reader.read_line(&mut buf)? == 0 {
                return Err(anyhow!("daemon closed connection"));
            }
            let v: Value = serde_json::from_str(&buf)?;
            if v.get("event").is_some() {
                if let Ok(e) = serde_json::from_value::<Event>(v) {
                    self.pending_events.push(e);
                }
                continue;
            }
            let r: Response = serde_json::from_value(v)?;
            if r.id != id {
                continue;
            }
            if let Some(e) = r.error {
                return Err(anyhow!(e));
            }
            return Ok(r.result.unwrap_or(Value::Null));
        }
    }

    /// Blocks until the next unsolicited event.
    pub fn next_event(&mut self) -> Result<Event> {
        if !self.pending_events.is_empty() {
            return Ok(self.pending_events.remove(0));
        }
        loop {
            let mut buf = String::new();
            if self.reader.read_line(&mut buf)? == 0 {
                return Err(anyhow!("daemon closed connection"));
            }
            let v: Value = serde_json::from_str(&buf)?;
            if v.get("event").is_some() {
                return Ok(serde_json::from_value(v)?);
            }
        }
    }
}

pub fn launch_agent_plist_path() -> std::path::PathBuf {
    crate::util::home_dir().join(format!("Library/LaunchAgents/{LAUNCH_LABEL}.plist"))
}

pub fn legacy_launch_agent_plist_path() -> std::path::PathBuf {
    crate::util::home_dir().join(format!("Library/LaunchAgents/{LEGACY_LAUNCH_LABEL}.plist"))
}

pub fn start_daemon(paths: &Paths) -> Result<()> {
    // Prefer the launchd job (keeps the daemon out of the caller's process coalition).
    if ade_proto::env_var_os("HOME").is_none() && launch_agent_plist_path().exists() {
        let uid = unsafe { libc::getuid() };
        let status = std::process::Command::new("launchctl")
            .args(["kickstart", &format!("gui/{uid}/{LAUNCH_LABEL}")])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
        if matches!(status, Ok(s) if s.success()) {
            return Ok(());
        }
    }
    spawn_detached(paths, &["daemon"])
}

/// Spawns `octomux <args>` fully detached (new session, no stdio).
pub fn spawn_detached(paths: &Paths, args: &[&str]) -> Result<()> {
    use std::os::unix::process::CommandExt;
    let exe = std::env::current_exe()?;
    crate::util::ensure_dir_0700(&paths.logs_dir())?;
    let log = std::fs::OpenOptions::new().create(true).append(true).open(paths.logs_dir().join("daemon.log"))?;
    let mut cmd = std::process::Command::new(exe);
    cmd.args(args)
        .env(ade_proto::HOME_VAR, &paths.home)
        .stdin(std::process::Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    cmd.spawn()?;
    Ok(())
}

/// `ade stdio`: relays stdin/stdout to this host's daemon socket (starting the daemon if needed),
/// so a client can reach it through any byte pipe, e.g. `ssh host ade stdio`.
pub fn stdio_bridge(paths: &Paths) -> Result<i32> {
    // Make sure a daemon runs, then open a raw connection for relaying.
    drop(Control::connect_or_spawn(paths)?);
    let sock = UnixStream::connect(paths.daemon_socket()).context("connect daemon")?;
    let mut to_daemon = sock.try_clone()?;
    let mut from_daemon = sock;
    let up = std::thread::spawn(move || {
        let _ = std::io::copy(&mut std::io::stdin().lock(), &mut to_daemon);
        let _ = to_daemon.shutdown(std::net::Shutdown::Write);
    });
    let mut out = std::io::stdout().lock();
    let mut buf = [0u8; 65536];
    loop {
        use std::io::{Read, Write};
        match from_daemon.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if out.write_all(&buf[..n]).is_err() || out.flush().is_err() {
                    break;
                }
            }
        }
    }
    drop(up);
    Ok(0)
}

