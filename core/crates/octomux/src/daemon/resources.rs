//! CPU and memory of each session's processes (Settings → Sessions), from one `ps` call.

use std::collections::HashMap;
use std::time::Instant;

pub struct Proc {
    pub pid: i32,
    pub ppid: i32,
    pub rss_kb: u64,
    /// Total CPU time so far, in seconds.
    pub cpu_secs: f64,
    /// `ps`'s own %CPU (a recent average on macOS, the lifetime average on Linux).
    pub pcpu: f64,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct Usage {
    pub rss_bytes: u64,
    pub cpu_percent: f64,
    pub processes: usize,
    /// The process using the most memory (`claude`, `node`).
    pub top: Option<String>,
}

pub fn process_table() -> Vec<Proc> {
    let Ok(out) = std::process::Command::new("ps").args(["-A", "-o", "pid=,ppid=,rss=,time=,%cpu=,comm="]).output() else { return vec![] };
    String::from_utf8_lossy(&out.stdout).lines().filter_map(parse_line).collect()
}

fn parse_line(l: &str) -> Option<Proc> {
    let mut it = l.split_whitespace();
    let pid = it.next()?.parse().ok()?;
    let ppid = it.next()?.parse().ok()?;
    let rss_kb = it.next()?.parse().ok()?;
    let cpu_secs = parse_time(it.next()?)?;
    let pcpu = it.next()?.replace(',', ".").parse().ok()?;
    let comm = it.collect::<Vec<_>>().join(" ");
    let name = comm.rsplit('/').next().unwrap_or(&comm).trim_start_matches('-').to_string();
    Some(Proc { pid, ppid, rss_kb, cpu_secs, pcpu, name })
}

/// `ps` TIME: `m:ss.cc` (macOS), `hh:mm:ss` or `d-hh:mm:ss` (Linux).
pub fn parse_time(t: &str) -> Option<f64> {
    let (days, rest) = match t.split_once('-') {
        Some((d, r)) => (d.parse::<f64>().ok()?, r),
        None => (0.0, t),
    };
    let mut secs = 0.0;
    for part in rest.split(':') {
        secs = secs * 60.0 + part.replace(',', ".").parse::<f64>().ok()?;
    }
    Some(days * 86400.0 + secs)
}

/// Every process under `root` (itself included).
fn tree(table: &[Proc], root: i32) -> Vec<&Proc> {
    let mut out: Vec<&Proc> = table.iter().filter(|p| p.pid == root).collect();
    let mut level = vec![root];
    for _ in 0..32 {
        let next: Vec<&Proc> = table.iter().filter(|p| level.contains(&p.ppid) && p.pid != p.ppid).collect();
        if next.is_empty() {
            break;
        }
        level = next.iter().map(|p| p.pid).collect();
        out.extend(next);
    }
    out
}

/// Usage per session root pid. CPU is measured since the previous call (`prev` keeps each process's CPU
/// time); a process seen for the first time counts with `ps`'s own %CPU.
pub fn usage(table: &[Proc], roots: &[(String, i32)], prev: &mut HashMap<i32, (f64, Instant)>) -> HashMap<String, Usage> {
    let now = Instant::now();
    let mut out = HashMap::new();
    let mut seen = HashMap::new();
    for (id, root) in roots {
        let procs = tree(table, *root);
        if procs.is_empty() {
            continue;
        }
        let mut cpu = 0.0;
        for p in &procs {
            cpu += match prev.get(&p.pid) {
                Some((t, at)) if now.duration_since(*at).as_secs_f64() > 0.2 && p.cpu_secs >= *t => {
                    (p.cpu_secs - t) / now.duration_since(*at).as_secs_f64() * 100.0
                }
                _ => p.pcpu,
            };
            seen.insert(p.pid, (p.cpu_secs, now));
        }
        let top = procs.iter().max_by_key(|p| p.rss_kb).map(|p| p.name.clone());
        out.insert(
            id.clone(),
            Usage { rss_bytes: procs.iter().map(|p| p.rss_kb * 1024).sum(), cpu_percent: (cpu * 10.0).round() / 10.0, processes: procs.len(), top },
        );
    }
    *prev = seen;
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times() {
        assert_eq!(parse_time("0:01.50"), Some(1.5));
        assert_eq!(parse_time("01:02:03"), Some(3723.0));
        assert_eq!(parse_time("2-00:00:10"), Some(172810.0));
        assert_eq!(parse_time("x"), None);
    }

    #[test]
    fn lines_and_trees() {
        let table: Vec<Proc> = [
            "  10     1  1000   0:01.00   1.0 -zsh",
            "  11    10  5000   0:10.00  20.5 /usr/local/bin/node server.js",
            "  12    11   500   0:00.10   0.0 sleep",
            "  20     1  9000   0:00.00   0.0 other",
        ]
        .iter()
        .filter_map(|l| parse_line(l))
        .collect();
        assert_eq!(table[0].name, "zsh");
        assert_eq!(table[1].name, "node server.js");
        let mut prev = HashMap::new();
        let u = usage(&table, &[("s".into(), 10)], &mut prev);
        let s = &u["s"];
        assert_eq!(s.processes, 3);
        assert_eq!(s.rss_bytes, 6500 * 1024);
        assert_eq!(s.cpu_percent, 21.5, "first sample: ps's %CPU");
        assert_eq!(s.top.as_deref(), Some("node server.js"));
        assert_eq!(prev.len(), 3);
    }
}
