//! Keep the Mac awake (Settings → Sessions → Keep Mac awake, the status bar's cup).
//!
//! `power.keep_awake`: "off" (default), "agents" (while an agent is working, plus a short grace so pauses
//! between steps don't count) or "always". While active the daemon holds `caffeinate -i -s -w <daemon pid>`:
//! no idle sleep (the display may still sleep), released by macOS itself if the daemon dies.
//!
//! `power.lid`: also when the lid is closed. macOS ignores assertions on lid close; only the system-wide
//! `pmset -a disablesleep 1` (root) holds it, through a sudoers rule limited to that command that the user
//! installs once from Settings (admin prompt). It is set only while keeping awake, only on the power adapter
//! unless `power.lid_on_battery`, and put back to 0 when that ends, on daemon start (after a crash) and exit.

use serde_json::{json, Value};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub const GRACE: Duration = Duration::from_secs(120);
const PMSET: &str = "/usr/bin/pmset";

#[derive(Default)]
pub struct Keeper {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    caffeinate: Option<Child>,
    /// We set `disablesleep 1` (and must put it back).
    lid_set: bool,
    last_working: Option<Instant>,
    last: Value,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Mode {
    Off,
    Agents,
    Always,
}

impl Mode {
    pub fn parse(v: Option<&Value>) -> Mode {
        match v.and_then(|v| v.as_str()) {
            Some("agents") => Mode::Agents,
            Some("always") => Mode::Always,
            _ => Mode::Off,
        }
    }
}

/// Whether to keep awake now. `since_working`: time since an agent was last seen working (None: never).
pub fn should_hold(mode: Mode, working: usize, since_working: Option<Duration>) -> bool {
    match mode {
        Mode::Off => false,
        Mode::Always => true,
        Mode::Agents => working > 0 || since_working.is_some_and(|d| d < GRACE),
    }
}

pub struct Inputs {
    pub mode: Mode,
    pub working: usize,
    pub lid: bool,
    pub lid_on_battery: bool,
}

impl Keeper {
    /// Applies the settings and the agents' state; returns the status the app shows.
    pub fn apply(&self, i: Inputs, marker: &std::path::Path) -> Value {
        let mut s = self.inner.lock().unwrap();
        if i.working > 0 {
            s.last_working = Some(Instant::now());
        }
        let hold = should_hold(i.mode, i.working, s.last_working.map(|t| t.elapsed()));

        // caffeinate: started when needed, restarted if it died.
        if let Some(c) = s.caffeinate.as_mut() {
            if !matches!(c.try_wait(), Ok(None)) {
                s.caffeinate = None;
            }
        }
        if hold && s.caffeinate.is_none() {
            s.caffeinate = Command::new("/usr/bin/caffeinate")
                .args(["-i", "-s", "-w", &std::process::id().to_string()])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .ok();
        } else if !hold {
            if let Some(mut c) = s.caffeinate.take() {
                let _ = c.kill();
                let _ = c.wait();
            }
        }

        // Closed lid: only with the rule installed, while holding, on AC unless allowed on battery.
        let on_ac = on_ac_power();
        // `sudo -n -l` only while the option is on (or the app asks, `power.rule_changed`).
        let setup = if i.lid { lid_rule_installed() } else { lid_rule_cached() };
        let want_lid = hold && i.lid && setup && (on_ac || i.lid_on_battery);
        if want_lid != s.lid_set {
            if set_disablesleep(want_lid) {
                s.lid_set = want_lid;
                if want_lid {
                    let _ = std::fs::write(marker, b"1");
                } else {
                    let _ = std::fs::remove_file(marker);
                }
            }
        }

        let st = json!({
            "mode": match i.mode { Mode::Off => "off", Mode::Agents => "agents", Mode::Always => "always" },
            "active": hold && s.caffeinate.is_some(),
            "working": i.working,
            "grace": i.mode == Mode::Agents && hold && i.working == 0,
            "lid": { "enabled": i.lid, "setup": setup, "active": s.lid_set, "on_ac": on_ac, "on_battery_allowed": i.lid_on_battery },
        });
        s.last = st.clone();
        st
    }

    pub fn status(&self) -> Value {
        self.inner.lock().unwrap().last.clone()
    }

    /// Daemon exit: lets the lid sleep again (caffeinate goes away with the daemon on its own).
    pub fn release(&self, marker: &std::path::Path) {
        let mut s = self.inner.lock().unwrap();
        if s.lid_set && set_disablesleep(false) {
            s.lid_set = false;
            let _ = std::fs::remove_file(marker);
        }
        if let Some(mut c) = s.caffeinate.take() {
            let _ = c.kill();
        }
    }
}

/// After a crash with the lid kept awake: puts `disablesleep` back once at start.
pub fn recover(marker: &std::path::Path) {
    if marker.exists() && set_disablesleep(false) {
        let _ = std::fs::remove_file(marker);
    }
}

/// `sudo -n pmset -a disablesleep 0|1` (needs the rule; never prompts).
fn set_disablesleep(on: bool) -> bool {
    Command::new("/usr/bin/sudo")
        .args(["-n", PMSET, "-a", "disablesleep", if on { "1" } else { "0" }])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

static RULE_CACHE: Mutex<Option<(Instant, bool)>> = Mutex::new(None);

/// The sudoers rule lets this user run `pmset -a disablesleep 1` without a password (checked at most every 30 s).
pub fn lid_rule_installed() -> bool {
    let mut c = RULE_CACHE.lock().unwrap();
    if let Some((t, v)) = *c {
        if t.elapsed() < Duration::from_secs(30) {
            return v;
        }
    }
    let v = Command::new("/usr/bin/sudo")
        .args(["-n", "-l", PMSET, "-a", "disablesleep", "1"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    *c = Some((Instant::now(), v));
    v
}

fn lid_rule_cached() -> bool {
    RULE_CACHE.lock().unwrap().map(|(_, v)| v).unwrap_or(false)
}

pub fn forget_rule_cache() {
    *RULE_CACHE.lock().unwrap() = None;
}

#[cfg(target_os = "macos")]
fn on_ac_power() -> bool {
    use std::ffi::c_void;
    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPSCopyPowerSourcesInfo() -> *const c_void;
        fn IOPSGetProvidingPowerSourceType(snapshot: *const c_void) -> *const c_void;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringGetCString(s: *const c_void, buf: *mut u8, len: isize, enc: u32) -> bool;
        fn CFRelease(cf: *const c_void);
    }
    unsafe {
        let snap = IOPSCopyPowerSourcesInfo();
        if snap.is_null() {
            return true;
        }
        let t = IOPSGetProvidingPowerSourceType(snap);
        let mut buf = [0u8; 64];
        let ok = !t.is_null() && CFStringGetCString(t, buf.as_mut_ptr(), buf.len() as isize, 0x0800_0100);
        CFRelease(snap);
        if !ok {
            return true;
        }
        let s = std::ffi::CStr::from_ptr(buf.as_ptr() as *const _).to_string_lossy();
        s != "Battery Power"
    }
}

#[cfg(not(target_os = "macos"))]
fn on_ac_power() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes_and_grace() {
        assert!(!should_hold(Mode::Off, 3, None));
        assert!(should_hold(Mode::Always, 0, None));
        assert!(should_hold(Mode::Agents, 1, None));
        assert!(!should_hold(Mode::Agents, 0, None));
        assert!(should_hold(Mode::Agents, 0, Some(Duration::from_secs(30))), "a pause between steps keeps it");
        assert!(!should_hold(Mode::Agents, 0, Some(GRACE + Duration::from_secs(1))));
        assert_eq!(Mode::parse(Some(&json!("agents"))), Mode::Agents);
        assert_eq!(Mode::parse(Some(&json!("nonsense"))), Mode::Off);
        assert_eq!(Mode::parse(None), Mode::Off);
    }
}
