#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("open failed: {0}")]
    Open(String),
    #[error("connect failed: {0}")]
    Connect(String),
    #[error("query failed: {0}")]
    Query(String),
    #[error("sync failed: {0}")]
    Sync(String),
    /// `push`/`pull` on a database opened without `remote_url`/`auth_token`.
    /// The text matches 0.1.x's `Sync` message, which older callers match on.
    #[error("sync failed: {0}() on a local-only database")]
    NotSynced(&'static str),
    /// The engine reported the database busy: another session or process
    /// holds it, or a write lock is contended.
    #[error("database is busy: {0}")]
    Busy(String),
    #[error("type error: {0}")]
    Type(String),
    #[error("database is closed")]
    Closed,
    /// An `*_interruptible` statement's interrupt flag was set while it waited
    /// for another statement on the same file. The statement did not run.
    #[error("statement interrupted before it ran")]
    Interrupted,
    /// A handle opened in one process was used in a forked child.
    #[error("database opened in process {opened} used after fork in process {current}; open a new database in the child")]
    Forked { opened: u32, current: u32 },
}

impl Error {
    /// Classifies an engine error: busy conditions become [`Error::Busy`]
    /// whatever the operation, everything else is wrapped by `kind`. The
    /// `"Database is busy"` text check mirrors turso's own `is_busy` (0.7.2 and 0.8.3)
    /// (`sync.rs`), which treats that `Error::Error` message as busy.
    pub(crate) fn from_engine(kind: fn(String) -> Error, e: turso::Error) -> Error {
        match e {
            turso::Error::Busy(m) | turso::Error::BusySnapshot(m) => Error::Busy(m),
            turso::Error::Error(m) if m.contains("Database is busy") => Error::Busy(m),
            other => kind(other.to_string()),
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;

#[cfg(test)]
mod tests {
    use super::Error;

    #[test]
    fn error_displays_context() {
        let e = Error::Query("boom".into());
        assert_eq!(e.to_string(), "query failed: boom");
    }
}
