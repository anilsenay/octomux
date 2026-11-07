//! Persistence: the in-memory `State` is the source of truth while running;
//! every mutation is written through to SQLite as JSON documents. A new kind of object (tasks) needs no
//! migration: it is one more `kind` in `objects`, and fields added later load through serde defaults.

use octomux_proto::control::{Notification, Session, State, StoredNotification};
use anyhow::Result;
use rusqlite::{Connection, params};
use serde::Serialize;
use serde::de::DeserializeOwned;
use std::path::Path;

pub struct Store {
    conn: Connection,
}

impl Store {
    pub fn open(path: &Path) -> Result<Store> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=NORMAL;
             CREATE TABLE IF NOT EXISTS objects(
                kind TEXT NOT NULL, id TEXT NOT NULL, json TEXT NOT NULL,
                PRIMARY KEY(kind, id));
             CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS notifications(
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, session_id TEXT NOT NULL,
                project_id TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
                read INTEGER NOT NULL DEFAULT 0);
             CREATE TABLE IF NOT EXISTS history(
                id TEXT PRIMARY KEY, project_id TEXT NOT NULL, last INTEGER NOT NULL, json TEXT NOT NULL);",
        )?;
        Ok(Store { conn })
    }

    fn load_kind<T: DeserializeOwned>(&self, kind: &str) -> Result<Vec<T>> {
        let mut stmt = self.conn.prepare("SELECT json FROM objects WHERE kind = ?1")?;
        let rows = stmt.query_map(params![kind], |r| r.get::<_, String>(0))?;
        let mut out = Vec::new();
        for r in rows {
            if let Ok(v) = serde_json::from_str(&r?) {
                out.push(v);
            }
        }
        Ok(out)
    }

    pub fn load(&self) -> Result<State> {
        let mut s = State {
            workspaces: self.load_kind("workspace")?,
            projects: self.load_kind("project")?,
            profiles: self.load_kind("profile")?,
            sessions: self.load_kind("session")?,
            tabs: self.load_kind("tab")?,
            settings: self.load_kind("setting")?,
            usage: self.load_kind("usage")?,
            tasks: self.load_kind("task")?,
        };
        s.workspaces.sort_by_key(|w| w.sort);
        s.projects.sort_by_key(|p| p.sort);
        s.profiles.sort_by_key(|p| p.sort);
        s.sessions.sort_by_key(|x| x.created_at);
        s.tabs.sort_by_key(|t| t.sort);
        s.tasks.sort_by(|a, b| a.created_at.cmp(&b.created_at).then_with(|| a.id.cmp(&b.id)));
        Ok(s)
    }

    pub fn put<T: Serialize>(&self, kind: &str, id: &str, value: &T) -> Result<()> {
        self.conn.execute(
            "INSERT INTO objects(kind, id, json) VALUES (?1, ?2, ?3)
             ON CONFLICT(kind, id) DO UPDATE SET json = excluded.json",
            params![kind, id, serde_json::to_string(value)?],
        )?;
        Ok(())
    }

    pub fn delete(&self, kind: &str, id: &str) -> Result<()> {
        self.conn.execute("DELETE FROM objects WHERE kind = ?1 AND id = ?2", params![kind, id])?;
        Ok(())
    }

    pub fn get_meta(&self, key: &str) -> Option<String> {
        self.conn.query_row("SELECT value FROM meta WHERE key = ?1", params![key], |r| r.get(0)).ok()
    }

    pub fn set_meta(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO meta(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    // MARK: notifications (kept outside `objects`: `save_all` rewrites that table)

    /// Stores a notification and returns it with its id and time. Keeps the newest 500.
    pub fn add_notification(&self, n: &Notification) -> Result<StoredNotification> {
        let ts = crate::util::now_secs() as i64;
        self.conn.execute(
            "INSERT INTO notifications(ts, session_id, project_id, kind, title, body, read) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0)",
            params![ts, n.session_id, n.project_id, n.kind, n.title, n.body],
        )?;
        let id = self.conn.last_insert_rowid();
        self.conn.execute("DELETE FROM notifications WHERE id <= ?1", params![id - 500])?;
        Ok(StoredNotification { id, ts, read: false, n: n.clone() })
    }

    pub fn notifications(&self, limit: i64) -> Result<Vec<StoredNotification>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, ts, session_id, project_id, kind, title, body, read FROM notifications ORDER BY id DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            Ok(StoredNotification {
                id: r.get(0)?,
                ts: r.get(1)?,
                read: r.get::<_, i64>(7)? != 0,
                n: Notification { session_id: r.get(2)?, project_id: r.get(3)?, kind: r.get(4)?, title: r.get(5)?, body: r.get(6)? },
            })
        })?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Marks notifications read: by ids, by session, or all (no filter). Returns how many changed.
    pub fn mark_notifications_read(&self, ids: Option<&[i64]>, session_id: Option<&str>) -> Result<usize> {
        Ok(match (ids, session_id) {
            (Some(ids), _) => {
                let mut n = 0;
                for id in ids {
                    n += self.conn.execute("UPDATE notifications SET read = 1 WHERE id = ?1 AND read = 0", params![id])?;
                }
                n
            }
            (None, Some(s)) => self.conn.execute("UPDATE notifications SET read = 1 WHERE session_id = ?1 AND read = 0", params![s])?,
            (None, None) => self.conn.execute("UPDATE notifications SET read = 1 WHERE read = 0", [])?,
        })
    }

    pub fn clear_notifications(&self) -> Result<()> {
        self.conn.execute("DELETE FROM notifications", [])?;
        Ok(())
    }

    // MARK: agent session history (survives removing the session)

    pub fn put_history(&self, s: &Session) -> Result<()> {
        self.conn.execute(
            "INSERT INTO history(id, project_id, last, json) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET project_id = excluded.project_id, last = excluded.last, json = excluded.json",
            params![s.id, s.project_id, s.last_activity_at.max(s.created_at) as i64, serde_json::to_string(s)?],
        )?;
        Ok(())
    }

    pub fn history(&self, project_id: Option<&str>, limit: i64) -> Result<Vec<Session>> {
        let mut out = Vec::new();
        let mut push = |json: String| {
            if let Ok(s) = serde_json::from_str::<Session>(&json) {
                out.push(s);
            }
        };
        if let Some(p) = project_id {
            let mut stmt = self.conn.prepare("SELECT json FROM history WHERE project_id = ?1 ORDER BY last DESC LIMIT ?2")?;
            for r in stmt.query_map(params![p, limit], |r| r.get::<_, String>(0))? {
                push(r?);
            }
        } else {
            let mut stmt = self.conn.prepare("SELECT json FROM history ORDER BY last DESC LIMIT ?1")?;
            for r in stmt.query_map(params![limit], |r| r.get::<_, String>(0))? {
                push(r?);
            }
        }
        Ok(out)
    }

    pub fn delete_history(&self, id: &str) -> Result<()> {
        self.conn.execute("DELETE FROM history WHERE id = ?1", params![id])?;
        Ok(())
    }

    /// Writes every object of the state (used after bulk changes).
    pub fn save_all(&self, s: &State) -> Result<()> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute("DELETE FROM objects", [])?;
        for w in &s.workspaces {
            self.put("workspace", &w.id, w)?;
        }
        for p in &s.projects {
            self.put("project", &p.id, p)?;
        }
        for p in &s.profiles {
            self.put("profile", &p.id, p)?;
        }
        for x in &s.sessions {
            self.put("session", &x.id, x)?;
        }
        for t in &s.tabs {
            self.put("tab", &t.id, t)?;
        }
        for st in &s.settings {
            self.put("setting", &format!("{}|{}", st.scope, st.key), st)?;
        }
        for t in &s.tasks {
            self.put("task", &t.id, t)?;
        }
        tx.commit()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use octomux_proto::control::{Task, TaskState};

    struct TempDb(std::path::PathBuf);

    impl TempDb {
        fn new(tag: &str) -> TempDb {
            let dir = std::env::temp_dir().join(format!("octomux-store-{tag}-{}-{}", std::process::id(), crate::util::short_id()));
            std::fs::create_dir_all(&dir).unwrap();
            TempDb(dir)
        }
        fn db(&self) -> std::path::PathBuf {
            self.0.join("octomux.sqlite3")
        }
    }

    impl Drop for TempDb {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn task(id: &str, created_at: u64) -> Task {
        serde_json::from_value(serde_json::json!({
            "id": id, "project_id": "p1", "title": format!("task {id}"), "state": "planned", "created_by": "user",
            "created_at": created_at, "updated_at": created_at,
        }))
        .unwrap()
    }

    #[test]
    fn tasks_round_trip_and_survive_save_all() {
        let tmp = TempDb::new("tasks");
        let store = Store::open(&tmp.db()).unwrap();
        let mut b = task("b", 20);
        b.sessions = vec!["s1".into(), "s2".into()];
        b.parent_id = Some("a".into());
        b.state = TaskState::ReadyToReview;
        b.pr_url = Some("https://example.com/pr/3".into());
        b.turns = 4;
        store.put("task", &b.id, &b).unwrap();
        store.put("task", "a", &task("a", 10)).unwrap();
        let st = store.load().unwrap();
        assert_eq!(st.tasks.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), vec!["a", "b"], "oldest first");
        assert_eq!(st.tasks[1], b);
        // Update in place, then delete.
        b.title = "renamed".into();
        store.put("task", &b.id, &b).unwrap();
        assert_eq!(store.load().unwrap().tasks[1].title, "renamed");
        store.delete("task", "a").unwrap();
        // save_all rewrites every object: tasks must be among them.
        let st = store.load().unwrap();
        store.save_all(&st).unwrap();
        drop(store);
        let st = Store::open(&tmp.db()).unwrap().load().unwrap();
        assert_eq!(st.tasks, vec![b]);
    }

    #[test]
    fn a_database_from_before_tasks_opens() {
        // Written by an older daemon: no tasks at all; later a task row lacking the optional fields.
        let tmp = TempDb::new("old");
        {
            let c = Connection::open(tmp.db()).unwrap();
            c.execute_batch(
                r##"CREATE TABLE objects(kind TEXT NOT NULL, id TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY(kind, id));
                 INSERT INTO objects VALUES ('workspace', 'w1', '{"id":"w1","name":"Personal","color":"#E8704A","sort":0}');"##,
            )
            .unwrap();
        }
        let store = Store::open(&tmp.db()).unwrap();
        let st = store.load().unwrap();
        assert_eq!(st.workspaces.len(), 1);
        assert!(st.tasks.is_empty());
        store
            .conn
            .execute(
                "INSERT INTO objects VALUES ('task', 't1', ?1)",
                params![r#"{"id":"t1","project_id":"p1","title":"bare","state":"done","created_by":"assistant","created_at":1,"updated_at":2}"#],
            )
            .unwrap();
        let t = &store.load().unwrap().tasks[0];
        assert_eq!((t.state, t.turns, t.description.as_str(), t.state_manual), (TaskState::Done, 0, "", false));
        assert!(t.sessions.is_empty() && t.parent_id.is_none());
        // The state the app gets always has the tasks array.
        let v = serde_json::to_value(State::default()).unwrap();
        assert_eq!(v["tasks"], serde_json::json!([]));
    }
}
