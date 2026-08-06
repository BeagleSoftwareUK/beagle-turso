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
    #[error("type error: {0}")]
    Type(String),
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
