//! Wire protocol shared by the Octomux daemon, session holders and clients.
//!
//! Two planes:
//! - **Data plane** (holder sockets): length-prefixed binary frames, see [`Frame`].
//! - **Control plane** (daemon socket): newline-delimited JSON, see [`control`].

use std::io::{self, Read, Write};
use std::path::PathBuf;

pub mod control;

/// Bumped on incompatible changes. Changes should be additive whenever possible.
pub const PROTOCOL_VERSION: u32 = 1;

/// Upper bound for a single frame payload (16 MiB).
pub const MAX_FRAME: usize = 16 * 1024 * 1024;

/// Frame kinds on a holder socket.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    // client -> holder
    Hello = 1,
    Input = 2,
    Resize = 3,
    Request = 4,
    // holder -> client
    Snapshot = 10,
    Output = 11,
    Event = 12,
    Response = 13,
    Exited = 14,
}

impl Kind {
    pub fn from_u8(b: u8) -> Option<Kind> {
        Some(match b {
            1 => Kind::Hello,
            2 => Kind::Input,
            3 => Kind::Resize,
            4 => Kind::Request,
            10 => Kind::Snapshot,
            11 => Kind::Output,
            12 => Kind::Event,
            13 => Kind::Response,
            14 => Kind::Exited,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub kind: Kind,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(kind: Kind, payload: impl Into<Vec<u8>>) -> Self {
        Frame { kind, payload: payload.into() }
    }

    pub fn json<T: serde::Serialize>(kind: Kind, value: &T) -> Self {
        Frame { kind, payload: serde_json::to_vec(value).expect("serializable") }
    }

    pub fn resize(cols: u16, rows: u16) -> Self {
        let mut p = Vec::with_capacity(4);
        p.extend_from_slice(&cols.to_be_bytes());
        p.extend_from_slice(&rows.to_be_bytes());
        Frame { kind: Kind::Resize, payload: p }
    }

    pub fn parse_resize(&self) -> Option<(u16, u16)> {
        if self.payload.len() != 4 {
            return None;
        }
        let cols = u16::from_be_bytes([self.payload[0], self.payload[1]]);
        let rows = u16::from_be_bytes([self.payload[2], self.payload[3]]);
        Some((cols, rows))
    }

    pub fn parse_json<T: serde::de::DeserializeOwned>(&self) -> io::Result<T> {
        serde_json::from_slice(&self.payload).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }

    /// Encodes as `[u32 BE length of (kind + payload)][kind][payload]`.
    pub fn encode(&self) -> Vec<u8> {
        let len = (self.payload.len() + 1) as u32;
        let mut out = Vec::with_capacity(self.payload.len() + 5);
        out.extend_from_slice(&len.to_be_bytes());
        out.push(self.kind as u8);
        out.extend_from_slice(&self.payload);
        out
    }

    pub fn write_to(&self, w: &mut impl Write) -> io::Result<()> {
        w.write_all(&self.encode())?;
        w.flush()
    }

    /// Reads one frame. Returns `Ok(None)` on clean EOF at a frame boundary.
    pub fn read_from(r: &mut impl Read) -> io::Result<Option<Frame>> {
        let mut len_buf = [0u8; 4];
        match read_exact_or_eof(r, &mut len_buf)? {
            false => return Ok(None),
            true => {}
        }
        let len = u32::from_be_bytes(len_buf) as usize;
        if len == 0 || len > MAX_FRAME + 1 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, format!("bad frame length {len}")));
        }
        let mut body = vec![0u8; len];
        r.read_exact(&mut body)?;
        let kind = Kind::from_u8(body[0])
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, format!("bad frame kind {}", body[0])))?;
        body.remove(0);
        Ok(Some(Frame { kind, payload: body }))
    }
}

fn read_exact_or_eof(r: &mut impl Read, buf: &mut [u8]) -> io::Result<bool> {
    let mut read = 0;
    while read < buf.len() {
        match r.read(&mut buf[read..]) {
            Ok(0) if read == 0 => return Ok(false),
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => read += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(true)
}

/// First frame a client sends to a holder.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct Hello {
    pub version: u32,
    pub role: Role,
    #[serde(default)]
    pub cols: u16,
    #[serde(default)]
    pub rows: u16,
}

#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    /// Interactive client: gets a snapshot then the live output, may send input and resizes.
    Attach,
    /// Receives events only (used by the daemon).
    Monitor,
    /// One-shot requests (tests, debugging).
    Control,
}

/// Requests over the holder data plane (`Kind::Request`).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum HolderRequest {
    Info,
    ScreenText,
    Snapshot,
    /// Signal the child process group (default SIGHUP then SIGKILL).
    Kill,
}

/// Holder -> monitor events (`Kind::Event`).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HolderEvent {
    Title { title: String },
    /// OSC 7501 program status: working | blocked | done | error | clear.
    ProgramStatus { state: String, #[serde(default)] app: String },
    /// OSC 9 / OSC 777 notifications emitted by programs.
    Notify { title: String, body: String },
    /// OSC 133 command lifecycle: `prompt`, `start`, or `end` with exit code.
    Command { phase: String, #[serde(default)] exit_code: Option<i32> },
    /// OSC 7 working directory report.
    Cwd { path: String },
    Bell,
    /// Activity heartbeat (output was produced). Rate limited.
    Activity,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct HolderInfo {
    pub id: String,
    pub pid: u32,
    pub child_pid: Option<u32>,
    pub cols: u16,
    pub rows: u16,
    pub title: String,
    pub started_at: u64,
    pub boot_time: u64,
    pub exited: Option<i32>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ExitInfo {
    pub code: Option<i32>,
    pub signal: Option<i32>,
}

/// Reads an Octomux environment variable, falling back to its pre-rename `ADE_*` name
/// (sessions and launchd agents started by older builds still carry those).
pub fn env_var_os(name: &str) -> Option<std::ffi::OsString> {
    std::env::var_os(format!("OCTOMUX_{name}")).or_else(|| std::env::var_os(format!("ADE_{name}"))).filter(|v| !v.is_empty())
}

const LEGACY_DB: &str = "ade.sqlite3";

/// Name of the data-directory variable set on child processes.
pub const HOME_VAR: &str = "OCTOMUX_HOME";

/// Filesystem layout. Everything lives under `OCTOMUX_HOME` (or the legacy `ADE_HOME`);
/// default `~/Library/Application Support/Octomux`, or the pre-rename `ade-dev` folder when only that exists
/// (it holds live session sockets, so it is used in place rather than moved).
#[derive(Debug, Clone)]
pub struct Paths {
    pub home: PathBuf,
}

impl Paths {
    pub fn from_env() -> Paths {
        if let Some(h) = env_var_os("HOME") {
            return Paths { home: PathBuf::from(h) };
        }
        let base = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"));
        let has_data = |p: &PathBuf| p.join("octomux.sqlite3").exists() || p.join(LEGACY_DB).exists();
        let mac = base.join("Library/Application Support/Octomux");
        let mac_legacy = base.join("Library/Application Support/ade-dev");
        if cfg!(target_os = "macos") {
            if !mac.exists() && has_data(&mac_legacy) {
                return Paths { home: mac_legacy };
            }
            return Paths { home: mac };
        }
        // Linux and others: $XDG_DATA_HOME/octomux, else ~/.local/share/octomux.
        let data = std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or_else(|| base.join(".local/share"));
        let xdg = data.join("octomux");
        if !xdg.exists() {
            // Pre-rename locations: $XDG_DATA_HOME/ade-dev, and early Linux builds used the macOS path.
            for legacy in [data.join("ade-dev"), mac_legacy] {
                if has_data(&legacy) {
                    return Paths { home: legacy };
                }
            }
        }
        Paths { home: xdg }
    }

    pub fn run_dir(&self) -> PathBuf {
        self.home.join("run")
    }
    /// Unix sockets have a ~104 byte path limit on macOS; session ids are kept short.
    pub fn holder_socket(&self, id: &str) -> PathBuf {
        self.run_dir().join(format!("{id}.sock"))
    }
    pub fn holder_info(&self, id: &str) -> PathBuf {
        self.run_dir().join(format!("{id}.json"))
    }
    pub fn holder_exit(&self, id: &str) -> PathBuf {
        self.run_dir().join(format!("{id}.exit"))
    }
    pub fn daemon_socket(&self) -> PathBuf {
        self.run_dir().join("daemon.sock")
    }
    pub fn db(&self) -> PathBuf {
        self.home.join("octomux.sqlite3")
    }
    /// The pre-rename database file; the daemon copies it to `db()` once and leaves it as a backup.
    pub fn legacy_db(&self) -> PathBuf {
        self.home.join(LEGACY_DB)
    }
    pub fn logs_dir(&self) -> PathBuf {
        self.home.join("logs")
    }
    pub fn agent_dir(&self) -> PathBuf {
        self.home.join("agent")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_roundtrip() {
        let frames = vec![
            Frame::new(Kind::Input, b"hello".to_vec()),
            Frame::resize(120, 40),
            Frame::new(Kind::Output, Vec::new()),
        ];
        let mut buf = Vec::new();
        for f in &frames {
            f.write_to(&mut buf).unwrap();
        }
        let mut cur = std::io::Cursor::new(buf);
        for f in &frames {
            assert_eq!(&Frame::read_from(&mut cur).unwrap().unwrap(), f);
        }
        assert!(Frame::read_from(&mut cur).unwrap().is_none());
        assert_eq!(frames[1].parse_resize(), Some((120, 40)));
    }
}
