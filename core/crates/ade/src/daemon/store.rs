//! Persistence: the in-memory `State` is the source of truth while running;
//! every mutation is written through to SQLite as JSON documents.

use ade_proto::control::State;
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
             CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);",
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
        };
        s.workspaces.sort_by_key(|w| w.sort);
        s.projects.sort_by_key(|p| p.sort);
        s.profiles.sort_by_key(|p| p.sort);
        s.sessions.sort_by_key(|x| x.created_at);
        s.tabs.sort_by_key(|t| t.sort);
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
        tx.commit()?;
        Ok(())
    }
}
