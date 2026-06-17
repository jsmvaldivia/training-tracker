//! Domain types for the training tracker.

/// Where a training/certification stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    NotStarted,
    InProgress,
    Completed,
}

impl Status {
    /// Stable string used for SQLite storage.
    pub fn as_db(self) -> &'static str {
        match self {
            Status::NotStarted => "not_started",
            Status::InProgress => "in_progress",
            Status::Completed => "completed",
        }
    }

    pub fn from_db(s: &str) -> Status {
        match s {
            "in_progress" => Status::InProgress,
            "completed" => Status::Completed,
            _ => Status::NotStarted,
        }
    }

    /// Human-friendly label for the UI.
    pub fn label(self) -> &'static str {
        match self {
            Status::NotStarted => "Not started",
            Status::InProgress => "In progress",
            Status::Completed => "Completed",
        }
    }

    pub const ALL: [Status; 3] = [Status::NotStarted, Status::InProgress, Status::Completed];
}

/// A single training or certification being tracked.
#[derive(Clone, Debug)]
pub struct Training {
    pub id: i64,
    pub name: String,
    pub status: Status,
    /// Completion percentage, 0..=100.
    pub progress: u8,
    /// Free-form target/goal date (e.g. "2026-12"). Empty when unset.
    pub target_date: String,
}
