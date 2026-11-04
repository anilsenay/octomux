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

/// The process's working directory.
pub fn cwd(pid: i32) -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as i32;
        let n = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDVNODEPATHINFO, 0, (&mut info as *mut libc::proc_vnodepathinfo).cast(), size) };
        if n != size {
            return None;
        }
        let raw = &info.pvi_cdir.vip_path;
        let bytes: Vec<u8> = raw.iter().flatten().map(|c| *c as u8).take_while(|c| *c != 0).collect();
        (!bytes.is_empty()).then(|| String::from_utf8_lossy(&bytes).into_owned())
    }
    #[cfg(not(target_os = "macos"))]
    {
        std::fs::read_link(format!("/proc/{pid}/cwd")).ok().map(|p| p.to_string_lossy().into_owned())
    }
}

/// When the process started (seconds since the epoch).
pub fn start_time(pid: i32) -> Option<u64> {
    #[cfg(target_os = "macos")]
    {
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
        let n = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&mut info as *mut libc::proc_bsdinfo).cast(), size) };
        (n == size).then_some(info.pbi_start_tvsec)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let m = std::fs::metadata(format!("/proc/{pid}")).ok()?.modified().ok()?;
        m.duration_since(std::time::UNIX_EPOCH).ok().map(|d| d.as_secs())
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

/// Paths of the regular files the process has open (Codex keeps its conversation's rollout file open).
pub fn open_files(pid: i32) -> Vec<String> {
    #[cfg(target_os = "macos")]
    {
        // <sys/proc_info.h>: PROC_PIDFDVNODEPATHINFO and `struct vnode_fdinfowithpath`, which libc lacks.
        const PROC_PIDFDVNODEPATHINFO: i32 = 2;
        #[repr(C)]
        struct VnodeFdInfoWithPath {
            pfi: [u64; 3], // struct proc_fileinfo
            pvip: libc::vnode_info_path,
        }
        let fd_size = std::mem::size_of::<libc::proc_fdinfo>();
        let need = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
        if need <= 0 {
            return vec![];
        }
        // Room for a few more descriptors opened in between.
        let mut fds: Vec<libc::proc_fdinfo> = vec![unsafe { std::mem::zeroed() }; need as usize / fd_size + 16];
        let got = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, fds.as_mut_ptr().cast(), (fds.len() * fd_size) as i32) };
        if got <= 0 {
            return vec![];
        }
        fds.truncate(got as usize / fd_size);
        let mut out = Vec::new();
        for fd in fds.iter().filter(|f| f.proc_fdtype == libc::PROX_FDTYPE_VNODE as u32) {
            let mut info: VnodeFdInfoWithPath = unsafe { std::mem::zeroed() };
            let size = std::mem::size_of::<VnodeFdInfoWithPath>() as i32;
            let n = unsafe { libc::proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, (&mut info as *mut VnodeFdInfoWithPath).cast(), size) };
            if n != size {
                continue;
            }
            let bytes: Vec<u8> = info.pvip.vip_path.iter().flatten().map(|c| *c as u8).take_while(|c| *c != 0).collect();
            if !bytes.is_empty() {
                out.push(String::from_utf8_lossy(&bytes).into_owned());
            }
        }
        out
    }
    #[cfg(not(target_os = "macos"))]
    {
        let Ok(rd) = std::fs::read_dir(format!("/proc/{pid}/fd")) else { return vec![] };
        rd.flatten().filter_map(|e| std::fs::read_link(e.path()).ok()).filter(|p| p.is_file()).map(|p| p.to_string_lossy().into_owned()).collect()
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn open_files_of_own_process() {
        let path = std::env::temp_dir().join(format!("octomux-open-{}", std::process::id()));
        let f = std::fs::File::create(&path).unwrap();
        let canon = path.canonicalize().unwrap().to_string_lossy().into_owned();
        assert!(super::open_files(std::process::id() as i32).contains(&canon));
        drop(f);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn own_process() {
        let me = std::process::id() as i32;
        assert!(super::parent(me).is_some_and(|p| p > 0));
        assert!(super::exe(me).is_some());
        assert!(!super::is_claude(me));
        let cwd = std::env::current_dir().unwrap().canonicalize().unwrap();
        assert_eq!(super::cwd(me).map(std::path::PathBuf::from), Some(cwd));
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
        assert!(super::start_time(me).is_some_and(|t| t <= now && now - t < 3600));
    }
}
