//! The last few hundred agent events (hooks, program status reports, activity changes), in memory, for
//! Settings → Advanced → Agent events and the diagnostics zip. No prompt text is kept.

use std::collections::VecDeque;
use std::sync::Mutex;

const CAP: usize = 500;

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct Event {
    /// Milliseconds since the epoch.
    pub ts: u64,
    pub session: String,
    /// "hook", "program" (OSC 7501) or "state" (an activity change, whatever caused it).
    pub source: String,
    pub name: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub detail: String,
}

#[derive(Default)]
pub struct EventLog {
    buf: Mutex<VecDeque<Event>>,
}

impl EventLog {
    pub fn push(&self, ts: u64, session: &str, source: &str, name: &str, detail: &str) {
        let mut b = self.buf.lock().unwrap();
        if b.len() >= CAP {
            b.pop_front();
        }
        b.push_back(Event { ts, session: session.into(), source: source.into(), name: name.into(), detail: detail.into() });
    }

    /// Oldest first; only one session's with `session`.
    pub fn list(&self, session: Option<&str>) -> Vec<Event> {
        self.buf.lock().unwrap().iter().filter(|e| session.is_none_or(|s| e.session == s)).cloned().collect()
    }
}

/// What a hook payload says beyond its name, without anything the user typed.
pub fn hook_detail(event: &str, payload: &serde_json::Value) -> String {
    let s = |k: &str| payload.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    match event {
        "PreToolUse" | "PostToolUse" | "PermissionRequest" => s("tool_name"),
        "Notification" => s("notification_type"),
        "SessionStart" | "SessionEnd" => [s("source"), s("reason")].into_iter().filter(|x| !x.is_empty()).collect::<Vec<_>>().join(" "),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_last_ones_and_filters() {
        let log = EventLog::default();
        for i in 0..(CAP + 5) {
            log.push(i as u64, if i % 2 == 0 { "a" } else { "b" }, "hook", "Stop", "");
        }
        let all = log.list(None);
        assert_eq!(all.len(), CAP);
        assert_eq!(all.first().unwrap().ts, 5);
        assert!(log.list(Some("a")).iter().all(|e| e.session == "a"));
    }

    #[test]
    fn details_never_carry_the_prompt() {
        let p = serde_json::json!({"prompt": "secret plan", "tool_name": "Bash", "notification_type": "permission_prompt"});
        assert_eq!(hook_detail("UserPromptSubmit", &p), "");
        assert_eq!(hook_detail("PreToolUse", &p), "Bash");
        assert_eq!(hook_detail("Notification", &p), "permission_prompt");
    }
}
