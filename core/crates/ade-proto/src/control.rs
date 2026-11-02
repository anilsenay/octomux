//! Control plane: newline-delimited JSON over the daemon socket.
//!
//! Client -> daemon: `{"id": 1, "method": "state.get", "params": {...}}`
//! Daemon -> client: `{"id": 1, "result": ...}` or `{"id": 1, "error": "..."}`
//! Daemon -> subscribed client (unsolicited): `{"event": "state", "data": ...}`

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub id: u64,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    pub id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub event: String,
    pub data: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    pub color: String,
    pub sort: i64,
    /// Optional icon: SF Symbol name or a single emoji. Shown in the workspace switcher.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Project {
    pub id: String,
    pub workspace_id: String,
    pub name: String,
    pub path: String,
    pub color: String,
    /// `{"kind": "folder" | "symbol" | "emoji" | "mascot" | "image", "value": "..."}`
    pub icon: Value,
    pub sort: i64,
    pub archived: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentKind {
    Claude,
    Codex,
    Generic,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub kind: AgentKind,
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub via_login_shell: bool,
    /// Generic agents only: e.g. `gemini --resume {id}`.
    #[serde(default)]
    pub resume_template: String,
    pub enabled: bool,
    pub pinned: bool,
    pub sort: i64,
    /// Claude: inject ADE's status line (usage limits). Off = hooks only, the user's status line untouched.
    #[serde(default = "yes")]
    pub statusline: bool,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SessionKind {
    Terminal,
    Agent,
    Action,
}

/// Process lifecycle of a session.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Running,
    /// Stopped by the user; kept in the sidebar, dimmed.
    Stopped,
    /// Process ended on its own.
    Exited,
    /// Holder vanished without the user asking (crash/reboot); restored automatically.
    Interrupted,
}

/// What the program inside is doing (agents mainly).
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Activity {
    Idle,
    Working,
    NeedsInput,
    Done,
    Error,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Placement {
    Tab,
    Dock,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Session {
    pub id: String,
    pub project_id: String,
    pub kind: SessionKind,
    pub profile_id: Option<String>,
    /// Title reported by the program (OSC 0/2) or derived.
    pub title: String,
    /// Title set by the user; wins over `title` when non-empty.
    pub custom_title: String,
    pub cwd: String,
    pub state: SessionState,
    pub activity: Activity,
    /// Finished/needs attention since the user last looked.
    pub unread: bool,
    /// Provider conversation id (Claude/Codex session id).
    pub agent_session_id: Option<String>,
    pub created_at: u64,
    pub last_activity_at: u64,
    pub exit_code: Option<i32>,
    pub placement: Placement,
    /// For `action` sessions: the command line.
    #[serde(default)]
    pub command: String,
    /// Git worktree directory this session belongs to (None = the project's main checkout).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<String>,
    /// Agent transcript file reported by hooks (`transcript_path`); used by the chat view.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<String>,
    /// Conversation title from the agent's transcript (Claude `custom-title`, else `ai-title`).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub agent_title: String,
}

/// Pane layout of a tab.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PaneNode {
    Leaf { session_id: String },
    Split { dir: SplitDir, ratio: f64, a: Box<PaneNode>, b: Box<PaneNode> },
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SplitDir {
    /// Side by side.
    Right,
    /// Stacked.
    Down,
}

impl PaneNode {
    pub fn sessions(&self) -> Vec<String> {
        match self {
            PaneNode::Leaf { session_id } => vec![session_id.clone()],
            PaneNode::Split { a, b, .. } => {
                let mut v = a.sessions();
                v.extend(b.sessions());
                v
            }
        }
    }

    /// Removes a session leaf. Returns `None` when the tree becomes empty.
    pub fn remove(self, id: &str) -> Option<PaneNode> {
        match self {
            PaneNode::Leaf { ref session_id } if session_id == id => None,
            PaneNode::Leaf { .. } => Some(self),
            PaneNode::Split { dir, ratio, a, b } => match (a.remove(id), b.remove(id)) {
                (None, None) => None,
                (Some(x), None) | (None, Some(x)) => Some(x),
                (Some(a), Some(b)) => Some(PaneNode::Split { dir, ratio, a: Box::new(a), b: Box::new(b) }),
            },
        }
    }

    /// Puts `new_id` next to the leaf `target`: split `dir`, before it (left / top) or after it.
    pub fn insert(self, target: &str, new_id: &str, dir: SplitDir, before: bool) -> (PaneNode, bool) {
        match self {
            PaneNode::Leaf { ref session_id } if session_id == target => {
                let new = Box::new(PaneNode::Leaf { session_id: new_id.to_string() });
                let old = Box::new(self.clone());
                let (a, b) = if before { (new, old) } else { (old, new) };
                (PaneNode::Split { dir, ratio: 0.5, a, b }, true)
            }
            PaneNode::Leaf { .. } => (self, false),
            PaneNode::Split { dir: d, ratio, a, b } => {
                let (a2, done) = a.insert(target, new_id, dir, before);
                if done {
                    return (PaneNode::Split { dir: d, ratio, a: Box::new(a2), b }, true);
                }
                let (b2, done) = b.insert(target, new_id, dir, before);
                (PaneNode::Split { dir: d, ratio, a: Box::new(a2), b: Box::new(b2) }, done)
            }
        }
    }

    /// Splits the leaf `target` so that `new_id` appears after it.
    pub fn split(self, target: &str, new_id: &str, dir: SplitDir) -> (PaneNode, bool) {
        match self {
            PaneNode::Leaf { ref session_id } if session_id == target => (
                PaneNode::Split {
                    dir,
                    ratio: 0.5,
                    a: Box::new(self.clone()),
                    b: Box::new(PaneNode::Leaf { session_id: new_id.to_string() }),
                },
                true,
            ),
            PaneNode::Leaf { .. } => (self, false),
            PaneNode::Split { dir: d, ratio, a, b } => {
                let (a2, done) = a.split(target, new_id, dir);
                if done {
                    return (PaneNode::Split { dir: d, ratio, a: Box::new(a2), b }, true);
                }
                let (b2, done) = b.split(target, new_id, dir);
                (PaneNode::Split { dir: d, ratio, a: Box::new(a2), b: Box::new(b2) }, done)
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Tab {
    pub id: String,
    pub project_id: String,
    pub sort: i64,
    pub layout: PaneNode,
    /// Focused pane inside the tab.
    pub active_session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Setting {
    /// `global`, `workspace:<id>` or `project:<id>`.
    pub scope: String,
    pub key: String,
    pub value: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct State {
    pub workspaces: Vec<Workspace>,
    pub projects: Vec<Project>,
    pub profiles: Vec<Profile>,
    pub sessions: Vec<Session>,
    pub tabs: Vec<Tab>,
    pub settings: Vec<Setting>,
    /// Latest rate-limit readings, one per (profile, window). Added in UI phase L.
    #[serde(default)]
    pub usage: Vec<UsageReading>,
}

/// One rate-limit window reading reported by an agent (Claude statusline payload,
/// Codex rollout). `used_percent` 0..100, times are Unix seconds.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct UsageReading {
    pub profile_id: String,
    /// `five_hour` | `seven_day` | `spend_limit` (Claude) or `primary` | `secondary` (Codex)
    pub window: String,
    pub used_percent: f64,
    pub resets_at: Option<i64>,
    pub observed_at: i64,
}

/// `notify` event payload: the app turns these into user notifications.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Notification {
    pub session_id: String,
    pub project_id: String,
    /// `done` | `needs_input` | `error` | `command_done` | `program`
    pub kind: String,
    pub title: String,
    pub body: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn leaf(s: &str) -> PaneNode {
        PaneNode::Leaf { session_id: s.into() }
    }

    #[test]
    fn split_and_remove() {
        let (t, ok) = leaf("a").split("a", "b", SplitDir::Right);
        assert!(ok);
        let (t, ok) = t.split("b", "c", SplitDir::Down);
        assert!(ok);
        assert_eq!(t.sessions(), vec!["a", "b", "c"]);
        let t = t.remove("b").unwrap();
        assert_eq!(t.sessions(), vec!["a", "c"]);
        let t = t.remove("a").unwrap();
        assert_eq!(t, leaf("c"));
        assert!(t.remove("c").is_none());
    }

    #[test]
    fn json_shape() {
        let n = leaf("x");
        assert_eq!(serde_json::to_string(&n).unwrap(), r#"{"type":"leaf","session_id":"x"}"#);
    }
}
