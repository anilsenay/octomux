//! Agent hook events that could not reach the daemon (it was restarting). The `hook` command appends them;
//! the daemon replays them once it is up, so a turn that ended meanwhile does not stay "working".

use octomux_proto::Paths;
use serde_json::{Value, json};
use std::io::Write;
use std::path::PathBuf;

/// Older entries are dropped: the session they describe has long moved on.
const MAX_AGE_MS: u64 = 10 * 60 * 1000;

fn path(paths: &Paths) -> PathBuf {
    paths.run_dir().join("hooks-pending.jsonl")
}

/// Keeps what the daemon reads from a hook (not tool inputs, which can be large).
pub fn append(paths: &Paths, params: &Value) {
    let p = params.get("payload");
    let keep = |k: &str| p.and_then(|p| p.get(k)).cloned().unwrap_or(Value::Null);
    let payload = json!({
        "session_id": keep("session_id"), "transcript_path": keep("transcript_path"),
        "notification_type": keep("notification_type"), "message": keep("message"),
    });
    let line = json!({ "ts": crate::util::now_millis(), "session_id": params["session_id"], "event": params["event"], "payload": payload });
    let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path(paths)) else { return };
    let _ = f.write_all(format!("{line}\n").as_bytes()); // one write per line: concurrent hooks don't interleave
}

/// Takes the pending events (oldest first): `(ts, session id, event, payload)`.
pub fn take(paths: &Paths) -> Vec<(u64, String, String, Value)> {
    let p = path(paths);
    let tmp = p.with_extension("replaying");
    if std::fs::rename(&p, &tmp).is_err() {
        return Vec::new();
    }
    let text = std::fs::read_to_string(&tmp).unwrap_or_default();
    let _ = std::fs::remove_file(&tmp);
    let now = crate::util::now_millis();
    text.lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter_map(|v| {
            let ts = v.get("ts")?.as_u64()?;
            Some((ts, v.get("session_id")?.as_str()?.to_string(), v.get("event")?.as_str()?.to_string(), v.get("payload").cloned().unwrap_or(Value::Null)))
        })
        .filter(|(ts, ..)| now.saturating_sub(*ts) < MAX_AGE_MS)
        .collect()
}
