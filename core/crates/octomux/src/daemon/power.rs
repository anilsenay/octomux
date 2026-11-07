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
//!
//! Safety limits, whatever the mode (so a forgotten setting or a stuck "working" agent can't keep a closed Mac
//! up for days): the lid may stay closed awake for at most `power.lid_max_hours` (default 8; 0 = no limit),
//! never below 20 % battery, and never under heavy thermal pressure. A limit ends it until the lid is opened
//! again, and says so in a notification.

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
    /// When the lid was seen closed (while it matters).
    lid_closed_since: Option<Instant>,
    /// A safety limit ended the closed-lid mode; cleared when the lid opens.
    tripped: Option<&'static str>,
}

pub const BATTERY_FLOOR: u32 = 20;
pub const DEFAULT_LID_HOURS: u64 = 8;

/// What a safety limit says when it stops the closed-lid mode.
pub fn trip_message(reason: &str, hours: u64) -> String {
    match reason {
        "time" => format!("Your Mac was kept awake with the lid closed for {hours} hour{}, the limit you set, so Octomux let it sleep.", if hours == 1 { "" } else { "s" }),
        "battery" => format!("The battery fell below {BATTERY_FLOOR}% with the lid closed, so Octomux let your Mac sleep."),
        _ => "Your Mac was getting hot with the lid closed, so Octomux let it sleep.".into(),
    }
}

/// Which limit (if any) applies now to a closed lid: closed for `closed`, battery `battery` (None on AC),
/// thermal pressure level `thermal` (0 nominal … 4).
pub fn limit_hit(closed: Duration, max: Option<Duration>, battery: Option<u32>, thermal: u64) -> Option<&'static str> {
    if thermal >= 2 {
        return Some("thermal");
    }
    if battery.is_some_and(|b| b < BATTERY_FLOOR) {
        return Some("battery");
    }
    if max.is_some_and(|m| closed >= m) {
        return Some("time");
    }
    None
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
    /// None: no limit.
    pub lid_max: Option<Duration>,
}

/// A safety limit stopped the closed-lid mode just now (to notify about).
pub struct Tripped {
    pub reason: &'static str,
}

impl Keeper {
    /// Applies the settings and the agents' state; returns the status the app shows.
    pub fn apply(&self, i: Inputs, marker: &std::path::Path) -> (Value, Option<Tripped>) {
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
        let mut want_lid = hold && i.lid && setup && (on_ac || i.lid_on_battery);
        // Safety limits: only looked at while the closed-lid mode is wanted or on.
        let mut tripped_now = None;
        if want_lid || s.lid_set {
            if lid_closed() {
                let since = *s.lid_closed_since.get_or_insert_with(Instant::now);
                if s.tripped.is_none() {
                    let battery = if on_ac { None } else { battery_percent() };
                    if let Some(r) = limit_hit(since.elapsed(), i.lid_max, battery, thermal_pressure()) {
                        s.tripped = Some(r);
                        tripped_now = Some(Tripped { reason: r });
                    }
                }
            } else {
                s.lid_closed_since = None;
                s.tripped = None;
            }
        }
        if s.tripped.is_some() {
            want_lid = false;
        }
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
            "lid": { "enabled": i.lid, "setup": setup, "active": s.lid_set, "on_ac": on_ac, "on_battery_allowed": i.lid_on_battery,
                     "max_hours": i.lid_max.map(|d| d.as_secs() / 3600).unwrap_or(0), "stopped": s.tripped },
        });
        s.last = st.clone();
        (st, tripped_now)
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

/// What the safety limits read right now (`power.probe`, for checking a machine).
pub fn probe() -> Value {
    json!({ "lid_closed_without_external_display": lid_closed(), "external_display": external_display_any(),
            "on_ac": on_ac_power(), "battery": battery_percent(), "thermal_pressure": thermal_pressure() })
}

#[cfg(target_os = "macos")]
fn external_display_any() -> bool {
    external_display()
}
#[cfg(not(target_os = "macos"))]
fn external_display_any() -> bool {
    false
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

/// The lid is closed with no external display (IOPMrootDomain's AppleClamshellState; no privileges needed).
/// With an external display a closed lid does not sleep the Mac anyway (clamshell mode), so that time is not
/// counted against the limit. (Not AppleClamshellCausesSleep: disablesleep itself may turn that off.)
#[cfg(target_os = "macos")]
fn lid_closed() -> bool {
    use std::ffi::c_void;
    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOServiceMatching(name: *const i8) -> *mut c_void;
        fn IOServiceGetMatchingService(port: u32, matching: *mut c_void) -> u32;
        fn IORegistryEntryCreateCFProperty(entry: u32, key: *const c_void, alloc: *const c_void, opts: u32) -> *const c_void;
        fn IOObjectRelease(o: u32) -> i32;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithCString(alloc: *const c_void, s: *const i8, enc: u32) -> *const c_void;
        fn CFBooleanGetValue(b: *const c_void) -> bool;
        fn CFRelease(cf: *const c_void);
    }
    unsafe {
        let svc = IOServiceGetMatchingService(0, IOServiceMatching(c"IOPMrootDomain".as_ptr()));
        if svc == 0 {
            return false;
        }
        let read = |name: &std::ffi::CStr| -> Option<bool> {
            let key = CFStringCreateWithCString(std::ptr::null(), name.as_ptr(), 0x0800_0100);
            let v = IORegistryEntryCreateCFProperty(svc, key, std::ptr::null(), 0);
            CFRelease(key);
            if v.is_null() {
                return None;
            }
            let b = CFBooleanGetValue(v);
            CFRelease(v);
            Some(b)
        };
        let closed = read(c"AppleClamshellState").unwrap_or(false);
        IOObjectRelease(svc);
        closed && !external_display()
    }
}

/// Some display other than the built-in one is connected.
#[cfg(target_os = "macos")]
fn external_display() -> bool {
    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGGetOnlineDisplayList(max: u32, ids: *mut u32, count: *mut u32) -> i32;
        fn CGDisplayIsBuiltin(id: u32) -> u32;
    }
    let mut ids = [0u32; 16];
    let mut n = 0u32;
    if unsafe { CGGetOnlineDisplayList(16, ids.as_mut_ptr(), &mut n) } != 0 {
        return false;
    }
    ids[..n as usize].iter().any(|&d| unsafe { CGDisplayIsBuiltin(d) } == 0)
}

#[cfg(not(target_os = "macos"))]
fn lid_closed() -> bool {
    false
}

/// Battery charge in percent (`pmset -g batt`), None when unknown.
fn battery_percent() -> Option<u32> {
    let out = Command::new(PMSET).args(["-g", "batt"]).stderr(Stdio::null()).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let i = text.find('%')?;
    let digits: String = text[..i].chars().rev().take_while(|c| c.is_ascii_digit()).collect::<Vec<_>>().into_iter().rev().collect();
    digits.parse().ok()
}

/// macOS thermal pressure level (0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping).
#[cfg(target_os = "macos")]
fn thermal_pressure() -> u64 {
    unsafe extern "C" {
        fn notify_register_check(name: *const i8, token: *mut i32) -> u32;
        fn notify_get_state(token: i32, state: *mut u64) -> u32;
    }
    static TOKEN: std::sync::OnceLock<Option<i32>> = std::sync::OnceLock::new();
    let token = *TOKEN.get_or_init(|| {
        let mut t = 0i32;
        (unsafe { notify_register_check(c"com.apple.system.thermalpressurelevel".as_ptr(), &mut t) } == 0).then_some(t)
    });
    let Some(t) = token else { return 0 };
    let mut v = 0u64;
    if unsafe { notify_get_state(t, &mut v) } == 0 { v } else { 0 }
}

#[cfg(not(target_os = "macos"))]
fn thermal_pressure() -> u64 {
    0
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

    #[test]
    fn closed_lid_limits() {
        let h = |n: u64| Duration::from_secs(n * 3600);
        assert_eq!(limit_hit(h(1), Some(h(8)), None, 0), None);
        assert_eq!(limit_hit(h(8), Some(h(8)), None, 0), Some("time"));
        assert_eq!(limit_hit(h(30), None, None, 0), None, "no limit set");
        assert_eq!(limit_hit(h(1), Some(h(8)), Some(19), 0), Some("battery"));
        assert_eq!(limit_hit(h(1), Some(h(8)), Some(60), 0), None);
        assert_eq!(limit_hit(h(1), None, Some(60), 2), Some("thermal"));
        assert_eq!(limit_hit(h(1), None, Some(60), 1), None);
        assert!(trip_message("time", 8).contains("8 hours"));
    }
}
