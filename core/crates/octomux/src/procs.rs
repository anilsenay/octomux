//! Small process-table lookups (parent, executable) without spawning `ps`.

pub fn parent(pid: i32) -> Option<i32> {
    #[cfg(target_os = "macos")]
    {
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
        let n = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&mut info as *mut libc::proc_bsdinfo).cast(), size) };
        (n == size).then_some(info.pbi_ppid as i32)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        // pid (comm) state ppid …; comm may contain spaces and parens, so split after the last ')'.
        stat.rsplit_once(')')?.1.split_whitespace().nth(1)?.parse().ok()
    }
}

pub fn exe(pid: i32) -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
        let n = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
        (n > 0).then(|| String::from_utf8_lossy(&buf[..n as usize]).into_owned())
    }
    #[cfg(not(target_os = "macos"))]
    {
        std::fs::read_link(format!("/proc/{pid}/exe")).ok().map(|p| p.to_string_lossy().into_owned())
    }
}

/// Claude Code's native binary (`…/claude/versions/<v>`, or a `claude` executable).
pub fn is_claude(pid: i32) -> bool {
    exe(pid).is_some_and(|p| p.contains("/claude/versions/") || p.rsplit('/').next() == Some("claude"))
}

/// Claude processes from `pid` up to init, nearest first.
pub fn claude_ancestors(pid: i32) -> usize {
    let (mut p, mut n) = (pid, 0);
    for _ in 0..64 {
        if p <= 1 {
            break;
        }
        if is_claude(p) {
            n += 1;
        }
        match parent(p) {
            Some(pp) if pp != p => p = pp,
            _ => break,
        }
    }
    n
}

#[cfg(test)]
mod tests {
    #[test]
    fn own_process() {
        let me = std::process::id() as i32;
        assert!(super::parent(me).is_some_and(|p| p > 0));
        assert!(super::exe(me).is_some());
        assert!(!super::is_claude(me));
    }
}
