//! SQLite persistence. Single local file, single connection — this is a
//! single-user app, so there is no pool and no server.

use rusqlite::{params, Connection};

use crate::model::{Status, Training};

pub struct Db {
    conn: Connection,
}

impl Db {
    /// Open (or create) the database file and ensure the schema exists.
    pub fn open(path: &str) -> rusqlite::Result<Db> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS trainings (
                id          INTEGER PRIMARY KEY,
                name        TEXT    NOT NULL,
                status      TEXT    NOT NULL DEFAULT 'not_started',
                progress    INTEGER NOT NULL DEFAULT 0,
                target_date TEXT    NOT NULL DEFAULT ''
            );",
        )?;
        Ok(Db { conn })
    }

    /// All trainings, newest first.
    pub fn list(&self) -> rusqlite::Result<Vec<Training>> {
        let mut stmt = self
            .conn
            .prepare("SELECT id, name, status, progress, target_date FROM trainings ORDER BY id DESC")?;
        let rows = stmt.query_map([], |row| {
            let status: String = row.get(2)?;
            let progress: i64 = row.get(3)?;
            Ok(Training {
                id: row.get(0)?,
                name: row.get(1)?,
                status: Status::from_db(&status),
                progress: progress.clamp(0, 100) as u8,
                target_date: row.get(4)?,
            })
        })?;
        rows.collect()
    }

    /// Insert a new training by name and return its row id.
    pub fn add(&self, name: &str) -> rusqlite::Result<i64> {
        self.conn
            .execute("INSERT INTO trainings (name) VALUES (?1)", params![name])?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Persist all editable fields of an existing training.
    pub fn update(&self, t: &Training) -> rusqlite::Result<()> {
        self.conn.execute(
            "UPDATE trainings SET name = ?1, status = ?2, progress = ?3, target_date = ?4 WHERE id = ?5",
            params![t.name, t.status.as_db(), t.progress as i64, t.target_date, t.id],
        )?;
        Ok(())
    }

    pub fn delete(&self, id: i64) -> rusqlite::Result<()> {
        self.conn
            .execute("DELETE FROM trainings WHERE id = ?1", params![id])?;
        Ok(())
    }
}
