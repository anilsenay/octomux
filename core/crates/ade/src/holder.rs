//! Session holder: one process per session. Owns the PTY and the child
//! process, keeps a headless VT screen, and serves clients over a Unix socket.
//! It is independent of the daemon: if the daemon dies or is upgraded, the
//! session keeps running.

use crate::util;
use ade_proto::{ExitInfo, Frame, Hello, HolderEvent, HolderInfo, HolderRequest, Kind, Paths, Role};
use anyhow::{Context, Result};
use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub struct HolderArgs {
    pub id: String,
    pub cwd: String,
    pub cols: u16,
    pub rows: u16,
    pub env: Vec<(String, String)>,
    pub argv: Vec<String>,
}

const SCROLLBACK: usize = 5000;
/// Scrollback lines replayed to a client on attach.
const HISTORY_REPLAY: usize = 3000;

/// vt100 callbacks collecting the side-channel events we care about.
#[derive(Default)]
struct Callbacks {
    events: Vec<HolderEvent>,
    /// Replies the terminal owes the program (DA/DSR) when no real terminal is attached.
    replies: Vec<Vec<u8>>,
    answer_queries: bool,
    title: String,
}

impl vt100::Callbacks for Callbacks {
    fn set_window_title(&mut self, _: &mut vt100::Screen, title: &[u8]) {
        let t = String::from_utf8_lossy(title).into_owned();
        if t != self.title {
            self.title = t.clone();
            self.events.push(HolderEvent::Title { title: t });
        }
    }

    fn set_window_icon_name(&mut self, s: &mut vt100::Screen, name: &[u8]) {
        // OSC 0 sets both; vt100 reports icon name separately. Treat as title.
        self.set_window_title(s, name);
    }

    fn audible_bell(&mut self, _: &mut vt100::Screen) {
        self.events.push(HolderEvent::Bell);
    }

    fn unhandled_osc(&mut self, _: &mut vt100::Screen, params: &[&[u8]]) {
        if let Some(ev) = parse_osc(params) {
            self.events.push(ev);
        }
    }

    fn unhandled_csi(&mut self, screen: &mut vt100::Screen, i1: Option<u8>, _i2: Option<u8>, params: &[&[u16]], c: char) {
        if !self.answer_queries {
            return;
        }
        match (i1, c) {
            // Primary device attributes: claim a VT220-ish terminal.
            (None, 'c') => self.replies.push(b"\x1b[?62;22c".to_vec()),
            // Cursor position report.
            (None, 'n') if params.first().and_then(|p| p.first()) == Some(&6) => {
                let (r, col) = screen.cursor_position();
                self.replies.push(format!("\x1b[{};{}R", r + 1, col + 1).into_bytes());
            }
            (None, 'n') if params.first().and_then(|p| p.first()) == Some(&5) => {
                self.replies.push(b"\x1b[0n".to_vec());
            }
            _ => {}
        }
    }
}

/// Environment variables that belong to an enclosing agent process, not to the user.
pub fn is_inherited_agent_var(key: &str, value: &str) -> bool {
    key == "CLAUDECODE"
        || key.starts_with("CLAUDE_CODE_")
        || matches!(key, "CLAUDE_PID" | "CLAUDE_EFFORT" | "CLAUDE_CONFIG_DIR" | "CODEX_SANDBOX" | "CODEX_SANDBOX_NETWORK_DISABLED")
        || (key == "GIT_EDITOR" && value.contains("claude"))
}

/// Parses the OSC sequences ADE cares about.
pub fn parse_osc(params: &[&[u8]]) -> Option<HolderEvent> {
    let s = |i: usize| params.get(i).map(|p| String::from_utf8_lossy(p).into_owned()).unwrap_or_default();
    match params.first().copied()? {
        b"7501" => {
            // OSC 7501 ; state=working:app=cargo:progress=40 ST
            let body = params[1..].iter().map(|p| String::from_utf8_lossy(p).into_owned()).collect::<Vec<_>>().join(";");
            let mut state = String::new();
            let mut app = String::new();
            let mut has_id = false;
            for kv in body.split(':') {
                let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
                match k {
                    "state" => state = v.to_string(),
                    "app" => app = v.to_string(),
                    "id" => has_id = !v.is_empty(),
                    _ => {}
                }
            }
            // Only the root record (no id) describes the program itself.
            if has_id || !matches!(state.as_str(), "working" | "blocked" | "done" | "error" | "clear") {
                return None;
            }
            Some(HolderEvent::ProgramStatus { state, app })
        }
        b"9" => {
            let first = s(1);
            // ConEmu progress (OSC 9;4;...) and other numeric subcommands are not notifications.
            if first.chars().all(|c| c.is_ascii_digit()) {
                return None;
            }
            let body = params[1..].iter().map(|p| String::from_utf8_lossy(p).into_owned()).collect::<Vec<_>>().join(";");
            Some(HolderEvent::Notify { title: String::new(), body })
        }
        b"777" if s(1) == "notify" => Some(HolderEvent::Notify { title: s(2), body: s(3) }),
        b"133" => {
            let phase = match s(1).as_str() {
                "A" => "prompt",
                "C" => "start",
                "D" => "end",
                _ => return None,
            };
            let exit_code = if phase == "end" { s(2).parse().ok() } else { None };
            Some(HolderEvent::Command { phase: phase.into(), exit_code })
        }
        b"7" => {
            let url = s(1);
            let path = url.strip_prefix("file://").map(|rest| rest.find('/').map(|i| &rest[i..]).unwrap_or(rest)).unwrap_or(&url);
            Some(HolderEvent::Cwd { path: percent_decode(path) })
        }
        _ => None,
    }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Escape sequences that recreate the current screen in a fresh terminal.
/// `main` is the main-screen image captured when the program switched to the
/// alternate screen; it is replayed first so leaving the alt screen shows it.
pub fn snapshot_bytes(screen: &vt100::Screen, title: &str, main: Option<&[u8]>) -> Vec<u8> {
    let mut out = Vec::new();
    // Reset attributes and clear, so a recycled terminal starts clean.
    out.extend_from_slice(b"\x1b[0m\x1b[H\x1b[2J");
    write_screen(&mut out, screen, title, main);
    out
}

/// Like [`snapshot_bytes`], but first replays up to `max_history` scrollback lines so
/// they land in the client's own scrollback (main screen only).
pub fn snapshot_with_history(screen: &mut vt100::Screen, title: &str, main: Option<&[u8]>, max_history: usize) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(b"\x1b[0m\x1b[H\x1b[2J");
    if !screen.alternate_screen() && max_history > 0 {
        let (rows, cols) = screen.size();
        screen.set_scrollback(usize::MAX);
        let total = screen.scrollback();
        if total > 0 {
            for i in total.saturating_sub(max_history)..total {
                screen.set_scrollback(total - i);
                if let Some(row) = screen.rows_formatted(0, cols).next() {
                    out.extend_from_slice(&row);
                }
                out.extend_from_slice(b"\x1b[0m\r\n");
            }
            // Push the replayed lines off the visible area before drawing the screen.
            for _ in 0..rows {
                out.extend_from_slice(b"\r\n");
            }
            out.extend_from_slice(b"\x1b[H\x1b[2J");
        }
        screen.set_scrollback(0);
    }
    write_screen(&mut out, screen, title, main);
    out
}

fn write_screen(out: &mut Vec<u8>, screen: &vt100::Screen, title: &str, main: Option<&[u8]>) {
    if screen.alternate_screen() {
        if let Some(m) = main {
            out.extend_from_slice(m);
            out.extend_from_slice(b"\x1b[0m");
        }
        out.extend_from_slice(b"\x1b[?1049h\x1b[H\x1b[2J");
    }
    out.extend_from_slice(&screen.contents_formatted());
    out.extend_from_slice(&screen.input_mode_formatted());
    out.extend_from_slice(&screen.cursor_state_formatted());
    if !title.is_empty() {
        out.extend_from_slice(format!("\x1b]2;{title}\x07").as_bytes());
    }
}

struct Client {
    id: u64,
    role: Role,
    tx: Sender<Vec<u8>>,
}

struct Inner {
    parser: vt100::Parser<Callbacks>,
    clients: Vec<Client>,
    next_client: u64,
    exited: Option<ExitInfo>,
    cols: u16,
    rows: u16,
    last_activity_event: Instant,
    /// Main screen as it was when the alternate screen was entered.
    main_snapshot: Option<Vec<u8>>,
}

const ALT_ENTER: &[&[u8]] = &[b"\x1b[?1049h", b"\x1b[?1047h", b"\x1b[?47h"];

fn find_alt_enter(data: &[u8]) -> Option<usize> {
    ALT_ENTER.iter().filter_map(|pat| data.windows(pat.len()).position(|w| w == *pat)).min()
}

impl Inner {
    /// Processes output, capturing the main screen right before an alt-screen switch.
    fn process(&mut self, data: &[u8]) {
        let mut rest = data;
        while !self.parser.screen().alternate_screen() {
            let Some(i) = find_alt_enter(rest) else { break };
            self.parser.process(&rest[..i]);
            let sc = self.parser.screen();
            let mut m = sc.contents_formatted();
            m.extend_from_slice(&sc.cursor_state_formatted());
            self.main_snapshot = Some(m);
            self.parser.process(&rest[i..i + 3]); // "\x1b[?" prefix; rest of the sequence follows
            rest = &rest[i + 3..];
        }
        self.parser.process(rest);
        if !self.parser.screen().alternate_screen() {
            self.main_snapshot = None;
        }
    }
}

struct Shared {
    id: String,
    paths: Paths,
    inner: Mutex<Inner>,
    pty_writer: Mutex<Box<dyn Write + Send>>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    child_pid: Option<u32>,
    started_at: u64,
    boot_time: u64,
}

impl Shared {
    fn info(&self) -> HolderInfo {
        let inner = self.inner.lock().unwrap();
        HolderInfo {
            id: self.id.clone(),
            pid: std::process::id(),
            child_pid: self.child_pid,
            cols: inner.cols,
            rows: inner.rows,
            title: inner.parser.callbacks().title.clone(),
            started_at: self.started_at,
            boot_time: self.boot_time,
            exited: inner.exited.as_ref().and_then(|e| e.code),
        }
    }

    fn broadcast_locked(inner: &mut Inner, role_filter: impl Fn(Role) -> bool, frame: &Frame) {
        let bytes = frame.encode();
        inner.clients.retain(|c| !role_filter(c.role) || c.tx.send(bytes.clone()).is_ok());
    }

    fn feed(&self, data: &[u8]) {
        let mut inner = self.inner.lock().unwrap();
        let attached = inner.clients.iter().any(|c| c.role == Role::Attach);
        inner.parser.callbacks_mut().answer_queries = !attached;
        inner.process(data);
        let events = std::mem::take(&mut inner.parser.callbacks_mut().events);
        let replies = std::mem::take(&mut inner.parser.callbacks_mut().replies);
        Self::broadcast_locked(&mut inner, |r| r == Role::Attach, &Frame::new(Kind::Output, data.to_vec()));
        for ev in events {
            Self::broadcast_locked(&mut inner, |r| r == Role::Monitor, &Frame::json(Kind::Event, &ev));
        }
        if inner.last_activity_event.elapsed() > Duration::from_millis(1000) {
            inner.last_activity_event = Instant::now();
            Self::broadcast_locked(&mut inner, |r| r == Role::Monitor, &Frame::json(Kind::Event, &HolderEvent::Activity));
        }
        drop(inner);
        if !replies.is_empty() {
            let mut w = self.pty_writer.lock().unwrap();
            for r in replies {
                let _ = w.write_all(&r);
            }
            let _ = w.flush();
        }
    }

    fn resize(&self, cols: u16, rows: u16) {
        if cols == 0 || rows == 0 {
            return;
        }
        let mut inner = self.inner.lock().unwrap();
        if inner.cols == cols && inner.rows == rows {
            return;
        }
        inner.cols = cols;
        inner.rows = rows;
        inner.parser.screen_mut().set_size(rows, cols);
        drop(inner);
        let _ = self.master.lock().unwrap().resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 });
        self.write_info();
    }

    fn write_input(&self, data: &[u8]) {
        let mut w = self.pty_writer.lock().unwrap();
        let _ = w.write_all(data);
        let _ = w.flush();
    }

    fn write_info(&self) {
        let info = self.info();
        let path = self.paths.holder_info(&self.id);
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, serde_json::to_vec(&info).unwrap()).is_ok() {
            let _ = std::fs::rename(tmp, path);
        }
    }

    fn kill_child(&self) {
        if let Some(pid) = self.child_pid {
            let pid = pid as i32;
            unsafe {
                // The child is a session leader on the PTY: signal its whole group.
                libc::kill(-pid, libc::SIGHUP);
                libc::kill(pid, libc::SIGHUP);
            }
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs(3));
                unsafe {
                    libc::kill(-pid, libc::SIGKILL);
                    libc::kill(pid, libc::SIGKILL);
                }
            });
        }
    }
}

pub fn run(paths: Paths, args: HolderArgs) -> Result<()> {
    util::ensure_dir_0700(&paths.run_dir())?;
    let sock_path = paths.holder_socket(&args.id);
    // A live holder already owns this id: refuse to start a second writer.
    if UnixStream::connect(&sock_path).is_ok() {
        anyhow::bail!("holder {} is already running", args.id);
    }
    let _ = std::fs::remove_file(&sock_path);
    let _ = std::fs::remove_file(paths.holder_exit(&args.id));

    let cols = if args.cols == 0 { 80 } else { args.cols };
    let rows = if args.rows == 0 { 24 } else { args.rows };
    let pty = native_pty_system();
    let pair = pty.openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 }).context("openpty")?;

    let mut cmd = if args.argv.is_empty() {
        let mut c = CommandBuilder::new(util::user_shell());
        c.arg("-l");
        c
    } else {
        let mut c = CommandBuilder::new(&args.argv[0]);
        c.args(&args.argv[1..]);
        c
    };
    let cwd = if std::path::Path::new(&args.cwd).is_dir() { args.cwd.clone() } else { util::home_dir().to_string_lossy().into_owned() };
    cmd.cwd(&cwd);
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
    cmd.env("TERM_PROGRAM", "ade");
    cmd.env("ADE_SESSION_ID", &args.id);
    // Never leak the environment of whatever started the daemon (e.g. a Claude Code
    // session) into user sessions: nested-agent markers disable transcripts and
    // CLAUDE_CONFIG_DIR would silently switch accounts. Profiles re-add what they need.
    for (k, v) in std::env::vars_os() {
        let k = k.to_string_lossy().into_owned();
        if is_inherited_agent_var(&k, &v.to_string_lossy()) {
            cmd.env_remove(&k);
        }
    }
    // launchd gives daemons no locale; without one, shells and TUIs mangle UTF-8 (ç, ğ, ş…).
    if std::env::var_os("LANG").is_none() && std::env::var_os("LC_ALL").is_none() && std::env::var_os("LC_CTYPE").is_none() {
        cmd.env("LANG", "en_US.UTF-8");
    }
    for (k, v) in &args.env {
        cmd.env(k, v);
    }
    let child = pair.slave.spawn_command(cmd).context("spawn child")?;
    drop(pair.slave);
    let child_pid = child.process_id();
    let reader = pair.master.try_clone_reader()?;
    let writer = pair.master.take_writer()?;

    let mut parser = vt100::Parser::new_with_callbacks(rows, cols, SCROLLBACK, Callbacks::default());
    parser.callbacks_mut().answer_queries = true;
    let shared = Arc::new(Shared {
        id: args.id.clone(),
        paths: paths.clone(),
        inner: Mutex::new(Inner {
            parser,
            clients: Vec::new(),
            next_client: 1,
            exited: None,
            cols,
            rows,
            last_activity_event: Instant::now() - Duration::from_secs(10),
            main_snapshot: None,
        }),
        pty_writer: Mutex::new(writer),
        master: Mutex::new(pair.master),
        child_pid,
        started_at: util::now_secs(),
        boot_time: util::boot_time(),
    });

    let listener = UnixListener::bind(&sock_path).with_context(|| format!("bind {}", sock_path.display()))?;
    util::set_mode_0600(&sock_path);
    shared.write_info();

    // PTY reader.
    {
        let shared = shared.clone();
        std::thread::spawn(move || {
            let mut reader = reader;
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => shared.feed(&buf[..n]),
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(_) => break,
                }
            }
        });
    }

    // Child waiter: on exit, record status, tell clients, and go away.
    {
        let shared = shared.clone();
        let mut child = child;
        std::thread::spawn(move || {
            let status = child.wait();
            // Give the reader a moment to drain the last output.
            std::thread::sleep(Duration::from_millis(150));
            let info = match status {
                Ok(s) => ExitInfo {
                    code: if s.signal().is_some() { None } else { Some(s.exit_code() as i32) },
                    signal: s.signal().map(|_| 1),
                },
                Err(_) => ExitInfo { code: None, signal: None },
            };
            let _ = std::fs::write(shared.paths.holder_exit(&shared.id), serde_json::to_vec(&info).unwrap());
            {
                let mut inner = shared.inner.lock().unwrap();
                inner.exited = Some(info.clone());
                Shared::broadcast_locked(&mut inner, |_| true, &Frame::json(Kind::Exited, &info));
            }
            shared.write_info();
            std::thread::sleep(Duration::from_millis(300));
            let _ = std::fs::remove_file(shared.paths.holder_socket(&shared.id));
            let _ = std::fs::remove_file(shared.paths.holder_info(&shared.id));
            std::process::exit(0);
        });
    }

    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let shared = shared.clone();
        std::thread::spawn(move || {
            let _ = serve_client(shared, stream);
        });
    }
    Ok(())
}

fn serve_client(shared: Arc<Shared>, stream: UnixStream) -> Result<()> {
    let mut reader = stream.try_clone()?;
    let Some(first) = Frame::read_from(&mut reader)? else { return Ok(()) };
    if first.kind != Kind::Hello {
        anyhow::bail!("expected hello");
    }
    let hello: Hello = first.parse_json()?;

    // Writer thread: frames are queued so one slow client never blocks the PTY.
    let (tx, rx) = channel::<Vec<u8>>();
    let mut wstream = stream.try_clone()?;
    std::thread::spawn(move || {
        for bytes in rx {
            if wstream.write_all(&bytes).is_err() {
                break;
            }
        }
        let _ = wstream.shutdown(std::net::Shutdown::Both);
    });

    let client_id;
    {
        let mut inner = shared.inner.lock().unwrap();
        client_id = inner.next_client;
        inner.next_client += 1;
        if hello.role == Role::Attach {
            // Size first, so the snapshot matches the client's grid.
            if hello.cols > 0 && hello.rows > 0 && (hello.cols != inner.cols || hello.rows != inner.rows) {
                drop(inner);
                shared.resize(hello.cols, hello.rows);
                inner = shared.inner.lock().unwrap();
            }
            let title = inner.parser.callbacks().title.clone();
            let main = inner.main_snapshot.clone();
            let snap = snapshot_with_history(inner.parser.screen_mut(), &title, main.as_deref(), HISTORY_REPLAY);
            let _ = tx.send(Frame::new(Kind::Snapshot, snap).encode());
        }
        if let Some(exit) = inner.exited.clone() {
            let _ = tx.send(Frame::json(Kind::Exited, &exit).encode());
        }
        if hello.role != Role::Control {
            inner.clients.push(Client { id: client_id, role: hello.role, tx: tx.clone() });
        }
    }

    loop {
        let frame = match Frame::read_from(&mut reader) {
            Ok(Some(f)) => f,
            _ => break,
        };
        match frame.kind {
            Kind::Input if hello.role == Role::Attach || hello.role == Role::Control => shared.write_input(&frame.payload),
            Kind::Resize => {
                if let Some((c, r)) = frame.parse_resize() {
                    shared.resize(c, r);
                }
            }
            Kind::Request => {
                let req: HolderRequest = frame.parse_json()?;
                let resp = match req {
                    HolderRequest::Info => serde_json::to_value(shared.info())?,
                    HolderRequest::ScreenText => {
                        let inner = shared.inner.lock().unwrap();
                        serde_json::json!({ "text": inner.parser.screen().contents(), "cursor": inner.parser.screen().cursor_position(), "alt": inner.parser.screen().alternate_screen() })
                    }
                    HolderRequest::Snapshot => {
                        let inner = shared.inner.lock().unwrap();
                        let title = inner.parser.callbacks().title.clone();
                        serde_json::json!({ "bytes": String::from_utf8_lossy(&snapshot_bytes(inner.parser.screen(), &title, inner.main_snapshot.as_deref())) })
                    }
                    HolderRequest::Kill => {
                        shared.kill_child();
                        serde_json::json!({ "ok": true })
                    }
                };
                let _ = tx.send(Frame::json(Kind::Response, &resp).encode());
            }
            _ => {}
        }
    }

    let mut inner = shared.inner.lock().unwrap();
    inner.clients.retain(|c| c.id != client_id);
    Ok(())
}

/// Small blocking client used by the daemon and tests.
pub struct HolderClient {
    stream: UnixStream,
}

impl HolderClient {
    pub fn connect(paths: &Paths, id: &str, role: Role, cols: u16, rows: u16) -> std::io::Result<HolderClient> {
        let mut stream = UnixStream::connect(paths.holder_socket(id))?;
        Frame::json(Kind::Hello, &Hello { version: ade_proto::PROTOCOL_VERSION, role, cols, rows }).write_to(&mut stream)?;
        Ok(HolderClient { stream })
    }

    pub fn request(paths: &Paths, id: &str, req: &HolderRequest) -> std::io::Result<serde_json::Value> {
        let mut c = HolderClient::connect(paths, id, Role::Control, 0, 0)?;
        c.stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        Frame::json(Kind::Request, req).write_to(&mut c.stream)?;
        loop {
            match Frame::read_from(&mut c.stream)? {
                Some(f) if f.kind == Kind::Response => return f.parse_json(),
                Some(_) => continue,
                None => return Err(std::io::ErrorKind::UnexpectedEof.into()),
            }
        }
    }

    pub fn send(&mut self, frame: &Frame) -> std::io::Result<()> {
        frame.write_to(&mut self.stream)
    }

    pub fn recv(&mut self) -> std::io::Result<Option<Frame>> {
        Frame::read_from(&mut self.stream)
    }

    pub fn set_read_timeout(&self, d: Option<Duration>) -> std::io::Result<()> {
        self.stream.set_read_timeout(d)
    }

    pub fn into_stream(self) -> UnixStream {
        self.stream
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Option<HolderEvent> {
        let parts: Vec<&[u8]> = s.split(';').map(|x| x.as_bytes()).collect();
        parse_osc(&parts)
    }

    #[test]
    fn osc_parsing() {
        assert_eq!(p("7501;state=working:app=claude"), Some(HolderEvent::ProgramStatus { state: "working".into(), app: "claude".into() }));
        assert_eq!(p("7501;state=done:id=build"), None);
        assert_eq!(p("7501;state=sleeping"), None);
        assert_eq!(p("9;hello world"), Some(HolderEvent::Notify { title: "".into(), body: "hello world".into() }));
        assert_eq!(p("9;4;1;50"), None);
        assert_eq!(p("777;notify;T;B"), Some(HolderEvent::Notify { title: "T".into(), body: "B".into() }));
        assert_eq!(p("133;D;2"), Some(HolderEvent::Command { phase: "end".into(), exit_code: Some(2) }));
        assert_eq!(p("133;A"), Some(HolderEvent::Command { phase: "prompt".into(), exit_code: None }));
        assert_eq!(p("7;file://host/Users/a%20b/x"), Some(HolderEvent::Cwd { path: "/Users/a b/x".into() }));
    }

    #[test]
    fn snapshot_recreates_screen() {
        let mut a = vt100::Parser::new(10, 40, 0);
        a.process(b"\x1b[31mred\x1b[0m line one\r\nsecond \xc3\xa7\xc4\x9f\xc3\xbc line\r\n\x1b[5;10Hcursor");
        let snap = snapshot_bytes(a.screen(), "", None);
        let mut b = vt100::Parser::new(10, 40, 0);
        b.process(b"garbage that should be cleared");
        b.process(&snap);
        assert_eq!(a.screen().contents(), b.screen().contents());
        assert_eq!(a.screen().cursor_position(), b.screen().cursor_position());
        assert_eq!(a.screen().cell(0, 0).unwrap().fgcolor(), b.screen().cell(0, 0).unwrap().fgcolor());
    }

    #[test]
    fn snapshot_replays_scrollback() {
        let mut a = vt100::Parser::new(10, 40, 1000);
        for i in 0..50 {
            a.process(format!("line {i}\r\n").as_bytes());
        }
        let snap = snapshot_with_history(a.screen_mut(), "", None, 3000);
        assert_eq!(a.screen().scrollback(), 0, "view restored");
        let mut b = vt100::Parser::new(10, 40, 1000);
        b.process(&snap);
        assert_eq!(a.screen().contents(), b.screen().contents());
        b.screen_mut().set_scrollback(usize::MAX);
        assert!(b.screen().scrollback() >= 41, "history replayed: {}", b.screen().scrollback());
        let top = b.screen().contents();
        assert!(top.starts_with("line 0\n"), "{top}");
    }

    #[test]
    fn snapshot_alt_screen() {
        let mut a = vt100::Parser::new(10, 40, 0);
        a.process(b"main\x1b[?1049h\x1b[Halt content\x1b[?2004h");
        let snap = snapshot_bytes(a.screen(), "", Some(b"main"));
        let mut b = vt100::Parser::new(10, 40, 0);
        b.process(&snap);
        assert!(b.screen().alternate_screen());
        assert!(b.screen().bracketed_paste());
        assert_eq!(b.screen().contents().trim(), "alt content");
        b.process(b"\x1b[?1049l");
        assert_eq!(b.screen().contents().trim(), "main");
    }
}
