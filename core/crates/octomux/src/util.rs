use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

pub fn now_millis() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Kernel boot time (seconds since epoch). Used to tell "ended by a reboot"
/// apart from "ended while the machine kept running".
pub fn boot_time() -> u64 {
    #[cfg(target_os = "macos")]
    unsafe {
        let mut tv: libc::timeval = std::mem::zeroed();
        let mut size = std::mem::size_of::<libc::timeval>();
        let name = c"kern.boottime";
        if libc::sysctlbyname(name.as_ptr(), &mut tv as *mut _ as *mut libc::c_void, &mut size, std::ptr::null_mut(), 0) == 0 {
            return tv.tv_sec as u64;
        }
        0
    }
    #[cfg(not(target_os = "macos"))]
    {
        // Linux: btime line in /proc/stat.
        std::fs::read_to_string("/proc/stat")
            .ok()
            .and_then(|s| s.lines().find(|l| l.starts_with("btime ")).and_then(|l| l[6..].trim().parse().ok()))
            .unwrap_or(0)
    }
}

pub fn short_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..12].to_string()
}

pub fn set_mode_0600(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
}

pub fn ensure_dir_0700(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
}

pub fn pid_alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM) }
}

pub fn home_dir() -> std::path::PathBuf {
    std::env::var_os("HOME").map(Into::into).unwrap_or_else(|| "/".into())
}

pub fn expand_tilde(p: &str) -> String {
    if let Some(rest) = p.strip_prefix("~/") {
        return home_dir().join(rest).to_string_lossy().into_owned();
    }
    if p == "~" {
        return home_dir().to_string_lossy().into_owned();
    }
    p.to_string()
}

pub fn shell_quote(s: &str) -> String {
    if !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:,@+%".contains(c)) {
        return s.to_string();
    }
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// The user's login shell (from the password database; launchd may not set $SHELL).
pub fn user_shell() -> String {
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if !pw.is_null() && !(*pw).pw_shell.is_null() {
            let s = std::ffi::CStr::from_ptr((*pw).pw_shell).to_string_lossy().into_owned();
            if !s.is_empty() {
                return s;
            }
        }
    }
    std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/zsh".into())
}
