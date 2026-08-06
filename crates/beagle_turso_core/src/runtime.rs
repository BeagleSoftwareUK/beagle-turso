use std::sync::Arc;
use tokio::runtime::{Builder, Runtime};

pub type SharedRt = Arc<Runtime>;

pub fn new_runtime() -> crate::Result<SharedRt> {
    let rt = Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
        .map_err(|e| crate::Error::Open(e.to_string()))?;
    Ok(Arc::new(rt))
}
