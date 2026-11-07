//! Tasks: Octomux's own work items. Pure functions over `State`; the daemon stores and broadcasts what
//! they change. `agent_call` is what agents reach through `octomux mcp` (tools `task_*`, `session_*`), with
//! the rules agents get: their tasks start as planned, they set only some states, and an assistant only
//! reaches the sessions of the tasks it owns.

use crate::util;
use anyhow::{Result, anyhow, bail};
use octomux_proto::control::{Session, State, Task, TaskState};
use serde_json::{Value, json};

/// What an agent may set a task's state to.
pub const AGENT_STATES: [TaskState; 4] = [TaskState::Planned, TaskState::Working, TaskState::ReadyToReview, TaskState::Done];

/// Prefix of the text `session_send` types into a session, so its user sees who wrote it.
pub const FROM_ASSISTANT: &str = "[from assistant] ";

pub fn valid_created_by(s: &str) -> bool {
    s == "user" || s == "assistant" || s.strip_prefix("agent:").is_some_and(|id| !id.is_empty())
}

fn parse_state(v: &Value) -> Result<TaskState> {
    let s = v.as_str().ok_or_else(|| anyhow!("state must be a string"))?;
    TaskState::parse(s).ok_or_else(|| anyhow!("unknown state {s} (planned, working, needs_you, ready_to_review, in_review, done)"))
}

/// A string field of a patch: absent = None, null or "" = Some(None) (clear), else Some(Some(v)).
fn patch_str(p: &Value, k: &str) -> Result<Option<Option<String>>> {
    match p.get(k) {
        None => Ok(None),
        Some(Value::Null) => Ok(Some(None)),
        Some(Value::String(s)) if s.trim().is_empty() => Ok(Some(None)),
        Some(Value::String(s)) => Ok(Some(Some(s.clone()))),
        Some(_) => bail!("{k} must be a string"),
    }
}

fn task<'a>(st: &'a State, id: &str) -> Result<&'a Task> {
    st.tasks.iter().find(|t| t.id == id).ok_or_else(|| anyhow!("no task {id}"))
}

fn workspace_of(st: &State, project_id: &str) -> Option<String> {
    st.projects.iter().find(|p| p.id == project_id).map(|p| p.workspace_id.clone())
}

/// Subtasks go one level deep: the parent must exist, be in the same project and have no parent itself,
/// and a task that has subtasks can't become one.
pub fn check_parent(st: &State, id: Option<&str>, project_id: &str, parent_id: &str) -> Result<()> {
    if id == Some(parent_id) {
        bail!("a task can't be its own parent");
    }
    let parent = task(st, parent_id).map_err(|_| anyhow!("no parent task {parent_id}"))?;
    if parent.parent_id.is_some() {
        bail!("{parent_id} is a subtask; subtasks can't have subtasks");
    }
    if parent.project_id != project_id {
        bail!("the parent task is in another project");
    }
    if let Some(id) = id
        && st.tasks.iter().any(|t| t.parent_id.as_deref() == Some(id))
    {
        bail!("{id} has subtasks, so it can't become one");
    }
    Ok(())
}

/// A new task from `task.create` params (not yet added to the state).
pub fn create(st: &State, p: &Value, now: u64) -> Result<Task> {
    let s = |k: &str| p.get(k).and_then(|v| v.as_str()).map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
    let project_id = s("project_id").ok_or_else(|| anyhow!("missing param project_id"))?;
    if !st.projects.iter().any(|x| x.id == project_id) {
        bail!("no project {project_id}");
    }
    let title = s("title").ok_or_else(|| anyhow!("missing param title"))?;
    let mut t = Task {
        id: util::short_id(),
        project_id,
        title,
        description: String::new(),
        parent_id: None,
        worktree: None,
        branch: None,
        sessions: Vec::new(),
        state: TaskState::Planned,
        state_manual: false,
        pr_url: None,
        source: None,
        agent_profile: None,
        created_by: "user".into(),
        assistant_session: None,
        turns: 0,
        created_at: now,
        updated_at: now,
    };
    apply(st, &mut t, p)?;
    Ok(t)
}

/// Applies a patch (any field but id, project_id and the times) to `t`, checking it against the state.
fn apply(st: &State, t: &mut Task, p: &Value) -> Result<()> {
    if !p.is_object() {
        bail!("params must be an object");
    }
    if let Some(v) = p.get("title") {
        let v = v.as_str().map(str::trim).filter(|v| !v.is_empty()).ok_or_else(|| anyhow!("title can't be empty"))?;
        t.title = v.to_string();
    }
    if let Some(v) = p.get("description") {
        t.description = match v {
            Value::Null => String::new(),
            Value::String(s) => s.clone(),
            _ => bail!("description must be a string"),
        };
    }
    if let Some(v) = patch_str(p, "parent_id")? {
        if let Some(parent) = &v {
            let existing = st.tasks.iter().any(|x| x.id == t.id).then_some(t.id.as_str());
            check_parent(st, existing, &t.project_id, parent)?;
        }
        t.parent_id = v;
    }
    if let Some(v) = patch_str(p, "worktree")? {
        t.worktree = v.map(|w| util::expand_tilde(&w));
    }
    if let Some(v) = patch_str(p, "branch")? {
        t.branch = v;
    }
    if let Some(v) = p.get("sessions") {
        let ids: Vec<String> = serde_json::from_value(v.clone()).map_err(|_| anyhow!("sessions must be an array of session ids"))?;
        let mut out: Vec<String> = Vec::new();
        for id in ids {
            if !out.contains(&id) {
                out.push(id);
            }
        }
        t.sessions = out;
    }
    if let Some(v) = p.get("state") {
        t.state = parse_state(v)?;
    }
    if let Some(v) = p.get("state_manual") {
        t.state_manual = v.as_bool().ok_or_else(|| anyhow!("state_manual must be true or false"))?;
    }
    if let Some(v) = patch_str(p, "pr_url")? {
        t.pr_url = v;
    }
    if let Some(v) = patch_str(p, "source")? {
        t.source = v;
    }
    if let Some(v) = patch_str(p, "agent_profile")? {
        if let Some(id) = &v
            && !st.profiles.iter().any(|x| &x.id == id)
        {
            bail!("no profile {id}");
        }
        t.agent_profile = v;
    }
    if let Some(v) = p.get("created_by") {
        let v = v.as_str().filter(|v| valid_created_by(v)).ok_or_else(|| anyhow!("created_by must be user, assistant or agent:<session id>"))?;
        t.created_by = v.to_string();
    }
    if let Some(v) = patch_str(p, "assistant_session")? {
        t.assistant_session = v;
    }
    if let Some(v) = p.get("turns") {
        t.turns = v.as_u64().and_then(|n| u32::try_from(n).ok()).ok_or_else(|| anyhow!("turns must be a whole number"))?;
    }
    Ok(())
}

/// `task.update`: patches the task in the state. Returns the tasks that changed (moving a task to another
/// project takes its subtasks along).
pub fn update(st: &mut State, id: &str, p: &Value, now: u64) -> Result<Vec<Task>> {
    let mut t = task(st, id)?.clone();
    let mut moved = Vec::new();
    if let Some(pid) = p.get("project_id").and_then(|v| v.as_str()).filter(|v| *v != t.project_id) {
        if !st.projects.iter().any(|x| x.id == pid) {
            bail!("no project {pid}");
        }
        // A subtask stays with its parent unless the patch also detaches it.
        let detached = matches!(patch_str(p, "parent_id")?, Some(None));
        if t.parent_id.is_some() && !detached {
            bail!("a subtask moves with its parent");
        }
        t.project_id = pid.to_string();
        moved = st.tasks.iter().filter(|x| x.parent_id.as_deref() == Some(id)).map(|x| x.id.clone()).collect();
    }
    apply(st, &mut t, p)?;
    t.updated_at = now;
    let mut changed = vec![t.clone()];
    for x in st.tasks.iter_mut() {
        if x.id == id {
            *x = t.clone();
        } else if moved.contains(&x.id) {
            x.project_id = t.project_id.clone();
            x.updated_at = now;
            changed.push(x.clone());
        }
    }
    Ok(changed)
}

/// Removes a task and its subtasks; returns their ids.
pub fn delete(st: &mut State, id: &str) -> Result<Vec<String>> {
    task(st, id)?;
    let ids: Vec<String> =
        st.tasks.iter().filter(|t| t.id == id || t.parent_id.as_deref() == Some(id)).map(|t| t.id.clone()).collect();
    st.tasks.retain(|t| !ids.contains(&t.id));
    Ok(ids)
}

/// Removes a project's tasks (the project is going away); returns their ids.
pub fn remove_project(st: &mut State, project_id: &str) -> Vec<String> {
    let ids: Vec<String> = st.tasks.iter().filter(|t| t.project_id == project_id).map(|t| t.id.clone()).collect();
    st.tasks.retain(|t| t.project_id != project_id);
    ids
}

/// `task.list`: filters by project, workspace and state(s) (a name or a list of names).
pub fn list(st: &State, p: &Value) -> Result<Vec<Task>> {
    let s = |k: &str| p.get(k).and_then(|v| v.as_str()).filter(|v| !v.is_empty());
    let states: Option<Vec<TaskState>> = match p.get("state") {
        None | Some(Value::Null) => None,
        Some(Value::Array(a)) => Some(a.iter().map(parse_state).collect::<Result<_>>()?),
        Some(v) => Some(vec![parse_state(v)?]),
    };
    let ws = s("workspace_id");
    Ok(st
        .tasks
        .iter()
        .filter(|t| s("project_id").is_none_or(|p| t.project_id == p))
        .filter(|t| ws.is_none_or(|w| workspace_of(st, &t.project_id).as_deref() == Some(w)))
        .filter(|t| states.as_ref().is_none_or(|v| v.contains(&t.state)))
        .cloned()
        .collect())
}

/// `task.add_session` / `task.remove_session`.
pub fn set_session(st: &mut State, id: &str, session_id: &str, add: bool, now: u64) -> Result<Task> {
    if add && !st.sessions.iter().any(|s| s.id == session_id) {
        bail!("no session {session_id}");
    }
    let t = st.tasks.iter_mut().find(|t| t.id == id).ok_or_else(|| anyhow!("no task {id}"))?;
    let had = t.sessions.iter().any(|s| s == session_id);
    if add && !had {
        t.sessions.push(session_id.to_string());
        t.updated_at = now;
    } else if !add && had {
        t.sessions.retain(|s| s != session_id);
        t.updated_at = now;
    }
    Ok(t.clone())
}

/// What an agent's tool call did, for the daemon to carry out.
#[derive(Debug, Default)]
pub struct AgentOutcome {
    pub reply: Value,
    /// Tasks to store (already changed in the state).
    pub changed: Vec<Task>,
    /// Text to type into a session (paste + Enter).
    pub send: Option<(String, String)>,
    /// An event for the app.
    pub event: Option<(String, Value)>,
}

fn reply(v: Value) -> AgentOutcome {
    AgentOutcome { reply: v, ..Default::default() }
}

/// The tasks an assistant owns that list `session_id`; empty = no access.
pub fn owned_tasks_with(st: &State, caller: &str, session_id: &str) -> Vec<String> {
    st.tasks
        .iter()
        .filter(|t| t.assistant_session.as_deref() == Some(caller) && t.sessions.iter().any(|s| s == session_id))
        .map(|t| t.id.clone())
        .collect()
}

fn summary(s: &Session, tasks: Vec<String>) -> Value {
    let title = [&s.custom_title, &s.agent_title, &s.title].into_iter().find(|t| !t.is_empty()).cloned().unwrap_or_default();
    json!({
        "id": s.id, "project_id": s.project_id, "title": title, "kind": s.kind, "state": s.state, "activity": s.activity,
        "unread": s.unread, "cwd": s.cwd, "worktree": s.worktree, "last_activity_at": s.last_activity_at,
        "created_at": s.created_at, "first_prompt": s.first_prompt, "tasks": tasks,
    })
}

/// One `octomux mcp` task/session tool call by the agent running in session `caller`.
pub fn agent_call(st: &mut State, caller: &str, tool: &str, args: &Value, now: u64) -> Result<AgentOutcome> {
    let me = st.sessions.iter().find(|s| s.id == caller).ok_or_else(|| anyhow!("unknown Octomux session {caller}"))?;
    let my_project = me.project_id.clone();
    let my_ws = workspace_of(st, &my_project).ok_or_else(|| anyhow!("this session's project is gone"))?;
    let arg = |k: &str| args.get(k).and_then(|v| v.as_str()).map(str::trim).filter(|v| !v.is_empty()).map(String::from);
    let need = |k: &str| arg(k).ok_or_else(|| anyhow!("missing argument {k}"));
    // Agents work within their session's workspace.
    let project = |st: &State, id: Option<String>| -> Result<String> {
        let id = id.unwrap_or_else(|| my_project.clone());
        match workspace_of(st, &id) {
            Some(w) if w == my_ws => Ok(id),
            Some(_) => bail!("project {id} is in another workspace"),
            None => bail!("no project {id}"),
        }
    };
    let my_task = |st: &State, id: &str| -> Result<Task> {
        let t = task(st, id)?;
        project(st, Some(t.project_id.clone()))?;
        Ok(t.clone())
    };
    let session_access = |st: &State, id: &str| -> Result<Vec<String>> {
        let owned = owned_tasks_with(st, caller, id);
        if owned.is_empty() {
            bail!("session {id} isn't part of a task you own (a task whose assistant_session is your session)");
        }
        Ok(owned)
    };
    match tool {
        "task_create" => {
            let project_id = project(st, arg("project_id"))?;
            let p = json!({
                "project_id": project_id, "title": need("title")?, "description": args.get("description").cloned().unwrap_or(Value::Null),
                "parent_id": arg("parent_id"), "state": "planned", "created_by": format!("agent:{caller}"),
            });
            let t = create(st, &p, now)?;
            st.tasks.push(t.clone());
            Ok(AgentOutcome { reply: serde_json::to_value(&t)?, changed: vec![t], ..Default::default() })
        }
        "task_list" => {
            let project_id = project(st, arg("project_id"))?;
            let mut f = json!({ "project_id": project_id });
            if let Some(s) = arg("state") {
                f["state"] = json!(s);
            }
            Ok(reply(json!({ "tasks": list(st, &f)? })))
        }
        "task_get" => Ok(reply(serde_json::to_value(my_task(st, &need("id")?)?)?)),
        "task_update" => {
            let id = need("id")?;
            my_task(st, &id)?;
            let mut patch = json!({});
            for k in ["title", "description"] {
                if let Some(v) = args.get(k) {
                    patch[k] = v.clone();
                }
            }
            if let Some(v) = args.get("state") {
                let s = parse_state(v)?;
                if !AGENT_STATES.contains(&s) {
                    bail!("agents can set the state to planned, working, ready_to_review or done, not {}", s.as_str());
                }
                patch["state"] = json!(s);
                patch["state_manual"] = json!(false);
            }
            let changed = update(st, &id, &patch, now)?;
            Ok(AgentOutcome { reply: serde_json::to_value(&changed[0])?, changed, ..Default::default() })
        }
        "task_start" => {
            let t = my_task(st, &need("id")?)?;
            if t.state != TaskState::Planned {
                bail!("task {} is {}; only planned tasks can be started", t.id, t.state.as_str());
            }
            let data = json!({ "task_id": t.id, "project_id": t.project_id, "requested_by": format!("agent:{caller}"), "caller_session": caller });
            Ok(AgentOutcome { reply: json!("requested"), event: Some(("task.start_requested".into(), data)), ..Default::default() })
        }
        "session_summary" => {
            let id = need("session_id")?;
            let owned = session_access(st, &id)?;
            let s = st.sessions.iter().find(|s| s.id == id).ok_or_else(|| anyhow!("session {id} was removed"))?;
            Ok(reply(summary(s, owned)))
        }
        "session_send" => {
            let id = need("session_id")?;
            session_access(st, &id)?;
            let text = args.get("text").and_then(|v| v.as_str()).filter(|t| !t.trim().is_empty()).ok_or_else(|| anyhow!("missing argument text"))?;
            let s = st.sessions.iter().find(|s| s.id == id).ok_or_else(|| anyhow!("session {id} was removed"))?;
            if s.state != octomux_proto::control::SessionState::Running {
                bail!("session {id} isn't running");
            }
            Ok(AgentOutcome { reply: json!("sent"), send: Some((id, format!("{FROM_ASSISTANT}{text}"))), ..Default::default() })
        }
        _ => bail!("unknown tool {tool}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use octomux_proto::control::*;

    fn session(id: &str, project: &str) -> Session {
        serde_json::from_value(json!({
            "id": id, "project_id": project, "kind": "agent", "profile_id": null, "title": "Claude", "custom_title": "",
            "cwd": "/tmp", "state": "running", "activity": "working", "unread": false, "agent_session_id": null,
            "created_at": 1, "last_activity_at": 5, "exit_code": null, "placement": "tab",
        }))
        .unwrap()
    }

    fn project(id: &str, ws: &str) -> Project {
        Project { id: id.into(), workspace_id: ws.into(), name: id.into(), path: "/tmp".into(), color: "#fff".into(), icon: json!({}), sort: 0, archived: false }
    }

    /// Workspace w1 with projects p1, p2 (sessions a1 = the assistant, s1, s2 in p1); w2 with p3 (session s3).
    fn state() -> State {
        State {
            projects: vec![project("p1", "w1"), project("p2", "w1"), project("p3", "w2")],
            sessions: vec![session("a1", "p1"), session("s1", "p1"), session("s2", "p1"), session("s3", "p3")],
            ..Default::default()
        }
    }

    fn add(st: &mut State, p: Value) -> Task {
        let t = create(st, &p, 100).unwrap();
        st.tasks.push(t.clone());
        t
    }

    #[test]
    fn create_defaults_and_fields() {
        let mut st = state();
        let t = add(&mut st, json!({ "project_id": "p1", "title": "  Fix login  " }));
        assert_eq!(t.title, "Fix login");
        assert_eq!(t.state, TaskState::Planned);
        assert_eq!(t.created_by, "user");
        assert_eq!((t.turns, t.created_at, t.updated_at), (0, 100, 100));
        assert_eq!(t.id.len(), 12);
        let u = add(&mut st, json!({ "project_id": "p1", "title": "x", "source": "jira:SHOP-12", "state": "working", "state_manual": true,
                                     "created_by": "agent:s1", "sessions": ["s1", "s1", "s2"], "branch": "fix/x", "turns": 3 }));
        assert_eq!(u.source.as_deref(), Some("jira:SHOP-12"));
        assert_eq!((u.state, u.state_manual, u.turns), (TaskState::Working, true, 3));
        assert_eq!(u.sessions, vec!["s1", "s2"]);
        assert!(create(&st, &json!({ "project_id": "p1" }), 0).is_err());
        assert!(create(&st, &json!({ "project_id": "nope", "title": "x" }), 0).is_err());
        assert!(create(&st, &json!({ "project_id": "p1", "title": "x", "state": "later" }), 0).is_err());
        assert!(create(&st, &json!({ "project_id": "p1", "title": "x", "created_by": "robot" }), 0).is_err());
        assert!(create(&st, &json!({ "project_id": "p1", "title": "x", "agent_profile": "nope" }), 0).is_err());
        // The JSON the app decodes.
        let v = serde_json::to_value(&u).unwrap();
        assert_eq!(v["state"], "working");
        assert!(v["pr_url"].is_null() && v["parent_id"].is_null());
    }

    #[test]
    fn subtasks_are_one_level_deep() {
        let mut st = state();
        let top = add(&mut st, json!({ "project_id": "p1", "title": "top" }));
        let sub = add(&mut st, json!({ "project_id": "p1", "title": "sub", "parent_id": top.id }));
        assert_eq!(sub.parent_id.as_deref(), Some(top.id.as_str()));
        let e = create(&st, &json!({ "project_id": "p1", "title": "deeper", "parent_id": sub.id }), 0).unwrap_err();
        assert!(e.to_string().contains("subtasks can't have subtasks"), "{e}");
        assert!(create(&st, &json!({ "project_id": "p1", "title": "x", "parent_id": "nope" }), 0).is_err());
        assert!(create(&st, &json!({ "project_id": "p2", "title": "x", "parent_id": top.id }), 0).is_err(), "other project");
        // A parent can't become a subtask, nor a task its own parent.
        let other = add(&mut st, json!({ "project_id": "p1", "title": "other" }));
        assert!(update(&mut st, &top.id, &json!({ "parent_id": other.id }), 1).is_err());
        assert!(update(&mut st, &other.id, &json!({ "parent_id": other.id }), 1).is_err());
        // Detaching with null, re-attaching.
        update(&mut st, &sub.id, &json!({ "parent_id": null }), 1).unwrap();
        assert!(task(&st, &sub.id).unwrap().parent_id.is_none());
        update(&mut st, &sub.id, &json!({ "parent_id": other.id }), 1).unwrap();
        assert_eq!(task(&st, &sub.id).unwrap().parent_id.as_deref(), Some(other.id.as_str()));
    }

    #[test]
    fn update_patches_only_what_is_given() {
        let mut st = state();
        let t = add(&mut st, json!({ "project_id": "p1", "title": "t", "description": "d", "branch": "b" }));
        let ch = update(&mut st, &t.id, &json!({ "state": "in_review", "pr_url": "https://x/pr/1", "turns": 2 }), 200).unwrap();
        let u = &ch[0];
        assert_eq!((u.title.as_str(), u.description.as_str(), u.branch.as_deref()), ("t", "d", Some("b")));
        assert_eq!((u.state, u.pr_url.as_deref(), u.turns, u.updated_at), (TaskState::InReview, Some("https://x/pr/1"), 2, 200));
        let u = &update(&mut st, &t.id, &json!({ "branch": null, "pr_url": "" }), 201).unwrap()[0];
        assert!(u.branch.is_none() && u.pr_url.is_none());
        assert!(update(&mut st, &t.id, &json!({ "title": "" }), 1).is_err());
        assert!(update(&mut st, "nope", &json!({}), 1).is_err());
        // Moving takes the subtasks along; a subtask alone can't move.
        let sub = add(&mut st, json!({ "project_id": "p1", "title": "s", "parent_id": t.id }));
        assert!(update(&mut st, &sub.id, &json!({ "project_id": "p2" }), 1).is_err());
        let ch = update(&mut st, &t.id, &json!({ "project_id": "p2" }), 300).unwrap();
        assert_eq!(ch.len(), 2);
        assert!(st.tasks.iter().all(|x| x.project_id == "p2"));
    }

    #[test]
    fn sessions_list_and_delete() {
        let mut st = state();
        let t = add(&mut st, json!({ "project_id": "p1", "title": "t" }));
        let sub = add(&mut st, json!({ "project_id": "p1", "title": "s", "parent_id": t.id, "state": "done" }));
        add(&mut st, json!({ "project_id": "p3", "title": "elsewhere" }));
        assert_eq!(set_session(&mut st, &t.id, "s1", true, 5).unwrap().sessions, vec!["s1"]);
        assert_eq!(set_session(&mut st, &t.id, "s1", true, 5).unwrap().sessions, vec!["s1"]);
        assert!(set_session(&mut st, &t.id, "ghost", true, 5).is_err());
        assert!(set_session(&mut st, &t.id, "s1", false, 6).unwrap().sessions.is_empty());

        assert_eq!(list(&st, &json!({})).unwrap().len(), 3);
        assert_eq!(list(&st, &json!({ "project_id": "p1" })).unwrap().len(), 2);
        assert_eq!(list(&st, &json!({ "workspace_id": "w2" })).unwrap().len(), 1);
        assert_eq!(list(&st, &json!({ "state": "done" })).unwrap()[0].id, sub.id);
        assert_eq!(list(&st, &json!({ "state": ["done", "planned"] })).unwrap().len(), 3);
        assert!(list(&st, &json!({ "state": "nope" })).is_err());

        let gone = delete(&mut st, &t.id).unwrap();
        assert_eq!(gone.len(), 2, "subtasks go with their parent");
        assert_eq!(remove_project(&mut st, "p3").len(), 1);
        assert!(st.tasks.is_empty());
    }

    #[test]
    fn agents_create_planned_tasks_as_themselves() {
        let mut st = state();
        let out = agent_call(&mut st, "s1", "task_create", &json!({ "title": "Add tests" }), 50).unwrap();
        let t = &out.changed[0];
        assert_eq!((t.state, t.created_by.as_str(), t.project_id.as_str()), (TaskState::Planned, "agent:s1", "p1"));
        assert!(!t.state_manual);
        assert_eq!(out.reply["id"], t.id.as_str());
        // Another project of the same workspace is fine; another workspace isn't.
        assert!(agent_call(&mut st, "s1", "task_create", &json!({ "title": "x", "project_id": "p2" }), 50).is_ok());
        assert!(agent_call(&mut st, "s1", "task_create", &json!({ "title": "x", "project_id": "p3" }), 50).is_err());
        assert!(agent_call(&mut st, "s1", "task_create", &json!({}), 50).is_err());
        assert!(agent_call(&mut st, "ghost", "task_create", &json!({ "title": "x" }), 50).is_err());
        // The listing defaults to the caller's project.
        let r = agent_call(&mut st, "s2", "task_list", &json!({}), 50).unwrap().reply;
        assert_eq!(r["tasks"].as_array().unwrap().len(), 1);
        let r = agent_call(&mut st, "s2", "task_list", &json!({ "state": "done" }), 50).unwrap().reply;
        assert!(r["tasks"].as_array().unwrap().is_empty());
        assert!(agent_call(&mut st, "s3", "task_get", &json!({ "id": t.id }), 50).is_err(), "other workspace");
    }

    #[test]
    fn agents_set_only_some_states() {
        let mut st = state();
        let t = add(&mut st, json!({ "project_id": "p1", "title": "t", "sessions": ["s2"], "state_manual": true }));
        for s in ["working", "ready_to_review", "done", "planned"] {
            let out = agent_call(&mut st, "s1", "task_update", &json!({ "id": t.id, "state": s }), 60).unwrap();
            assert_eq!(out.changed[0].state.as_str(), s);
            assert!(!out.changed[0].state_manual);
        }
        for s in ["in_review", "needs_you", "bogus"] {
            assert!(agent_call(&mut st, "s1", "task_update", &json!({ "id": t.id, "state": s }), 60).is_err(), "{s}");
        }
        // Fields beyond title/description/state are not taken from agents.
        let out = agent_call(&mut st, "s1", "task_update", &json!({ "id": t.id, "title": "New", "sessions": [], "assistant_session": "s1" }), 61).unwrap();
        assert_eq!(out.changed[0].title, "New");
        assert_eq!(out.changed[0].sessions, vec!["s2"]);
        assert!(out.changed[0].assistant_session.is_none());
    }

    #[test]
    fn assistant_reaches_only_sessions_of_its_tasks() {
        let mut st = state();
        add(&mut st, json!({ "project_id": "p1", "title": "mine", "assistant_session": "a1", "sessions": ["s1"] }));
        add(&mut st, json!({ "project_id": "p1", "title": "not mine", "sessions": ["s2"] }));
        let r = agent_call(&mut st, "a1", "session_summary", &json!({ "session_id": "s1" }), 0).unwrap().reply;
        assert_eq!((r["id"].as_str(), r["activity"].as_str(), r["cwd"].as_str()), (Some("s1"), Some("working"), Some("/tmp")));
        assert_eq!(r["last_activity_at"], 5);
        let e = agent_call(&mut st, "a1", "session_summary", &json!({ "session_id": "s2" }), 0).unwrap_err();
        assert!(e.to_string().contains("isn't part of a task you own"), "{e}");
        assert!(agent_call(&mut st, "s2", "session_summary", &json!({ "session_id": "s1" }), 0).is_err(), "not the owner");

        let out = agent_call(&mut st, "a1", "session_send", &json!({ "session_id": "s1", "text": "run the tests" }), 0).unwrap();
        assert_eq!(out.send, Some(("s1".into(), "[from assistant] run the tests".into())));
        assert!(agent_call(&mut st, "a1", "session_send", &json!({ "session_id": "s2", "text": "hi" }), 0).is_err());
        assert!(agent_call(&mut st, "a1", "session_send", &json!({ "session_id": "s1", "text": " " }), 0).is_err());
        st.sessions.iter_mut().find(|s| s.id == "s1").unwrap().state = SessionState::Stopped;
        assert!(agent_call(&mut st, "a1", "session_send", &json!({ "session_id": "s1", "text": "hi" }), 0).is_err());
    }

    #[test]
    fn start_is_a_request_for_the_app() {
        let mut st = state();
        let t = add(&mut st, json!({ "project_id": "p1", "title": "t" }));
        let out = agent_call(&mut st, "a1", "task_start", &json!({ "id": t.id }), 0).unwrap();
        assert_eq!(out.reply, json!("requested"));
        let (name, data) = out.event.unwrap();
        assert_eq!(name, "task.start_requested");
        assert_eq!(data, json!({ "task_id": t.id, "project_id": "p1", "requested_by": "agent:a1", "caller_session": "a1" }));
        assert!(out.changed.is_empty());
        update(&mut st, &t.id, &json!({ "state": "working" }), 1).unwrap();
        assert!(agent_call(&mut st, "a1", "task_start", &json!({ "id": t.id }), 0).is_err());
    }
}
