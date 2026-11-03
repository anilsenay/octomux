//! `ade attach <session>`: a tiny byte proxy between the terminal it runs in
//! (e.g. a libghostty surface) and a session holder.

use crate::client::Control;
use crate::holder::HolderClient;
use octomux_proto::{ExitInfo, Frame, Kind, Paths, Role};
use anyhow::Result;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

struct RawMode {
    fd: i32,
    orig: libc::termios,
}

impl RawMode {
    fn enable(fd: i32) -> Option<RawMode> {
        unsafe {
            if libc::isatty(fd) == 0 {
                return None;
            }
            let mut t: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(fd, &mut t) != 0 {
                return None;
            }
            let orig = t;
            libc::cfmakeraw(&mut t);
            libc::tcsetattr(fd, libc::TCSANOW, &t);
            Some(RawMode { fd, orig })
        }
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        unsafe {
            libc::tcsetattr(self.fd, libc::TCSANOW, &self.orig);
        }
    }
}

pub fn winsize(fd: i32) -> Option<(u16, u16)> {
    unsafe {
        let mut ws: libc::winsize = std::mem::zeroed();
        if libc::ioctl(fd, libc::TIOCGWINSZ, &mut ws) == 0 && ws.ws_col > 0 {
            Some((ws.ws_col, ws.ws_row))
        } else {
            None
        }
    }
}

fn connect_with_ensure(paths: &Paths, id: &str, cols: u16, rows: u16) -> Result<HolderClient> {
    if let Ok(c) = HolderClient::connect(paths, id, Role::Attach, cols, rows) {
        return Ok(c);
    }
    // Not running: ask the daemon to start or restore it.
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut asked = false;
    loop {
        if !asked {
            if let Ok(mut ctl) = Control::connect_or_spawn(paths) {
                let _ = ctl.call("session.ensure", serde_json::json!({ "id": id, "cols": cols, "rows": rows }));
                asked = true;
            }
        }
        std::thread::sleep(Duration::from_millis(100));
        if let Ok(c) = HolderClient::connect(paths, id, Role::Attach, cols, rows) {
            return Ok(c);
        }
        if Instant::now() > deadline {
            anyhow::bail!("session {id} is not running");
        }
    }
}

pub fn run(paths: Paths, id: String) -> Result<i32> {
    let stdin_fd = std::io::stdin().as_raw_fd();
    let (cols, rows) = winsize(stdin_fd).unwrap_or((80, 24));
    let client = match connect_with_ensure(&paths, &id, cols, rows) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("\r\n[ade] {e}\r\n");
            return Ok(1);
        }
    };
    let _raw = RawMode::enable(stdin_fd);
    let stream = client.into_stream();
    let done = Arc::new(AtomicBool::new(false));

    // stdin -> holder
    {
        let mut w = stream.try_clone()?;
        let done = done.clone();
        std::thread::spawn(move || {
            let mut stdin = std::io::stdin();
            let mut buf = [0u8; 16 * 1024];
            while !done.load(Ordering::Relaxed) {
                match stdin.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if Frame::new(Kind::Input, buf[..n].to_vec()).write_to(&mut w).is_err() {
                            break;
                        }
                    }
                }
            }
        });
    }

    // SIGWINCH -> resize
    {
        let mut w = stream.try_clone()?;
        let mut signals = signal_hook::iterator::Signals::new([signal_hook::consts::SIGWINCH])?;
        std::thread::spawn(move || {
            let mut last = (cols, rows);
            for _ in signals.forever() {
                if let Some(sz) = winsize(stdin_fd) {
                    if sz != last {
                        last = sz;
                        if Frame::resize(sz.0, sz.1).write_to(&mut w).is_err() {
                            break;
                        }
                    }
                }
            }
        });
    }

    // holder -> stdout
    let mut r = stream;
    let mut stdout = std::io::stdout().lock();
    let mut code = 0;
    loop {
        match Frame::read_from(&mut r) {
            Ok(Some(f)) => match f.kind {
                Kind::Snapshot | Kind::Output => {
                    if stdout.write_all(&f.payload).is_err() {
                        break;
                    }
                    let _ = stdout.flush();
                }
                Kind::Exited => {
                    let info: ExitInfo = f.parse_json().unwrap_or(ExitInfo { code: None, signal: None });
                    code = info.code.unwrap_or(1);
                    break;
                }
                _ => {}
            },
            _ => break,
        }
    }
    done.store(true, Ordering::Relaxed);
    Ok(code)
}
