// Spike 2b: drive the real turso engine from Ruby, through Magnus.
// Ruby calls TursoSpike.ping -> Rust opens an in-memory turso DB, runs SQL,
// and returns the queried value back to Ruby. Proves the full
// Ruby -> Rust (Magnus) -> turso engine path in-process.

use magnus::{function, prelude::*, Error, Ruby};
use turso::Builder;

// Convert any Display error into a Ruby-raisable Magnus error.
fn se<E: std::fmt::Display>(e: E) -> Error {
    Error::new(magnus::exception::runtime_error(), e.to_string())
}

fn ping() -> Result<String, Error> {
    // Magnus methods are sync; the turso API is async — block on a small runtime.
    let rt = tokio::runtime::Runtime::new().map_err(se)?;
    rt.block_on(async {
        let db = Builder::new_local(":memory:").build().await.map_err(se)?;
        let conn = db.connect().map_err(se)?;
        conn.execute("CREATE TABLE t (x TEXT)", ()).await.map_err(se)?;
        conn.execute("INSERT INTO t (x) VALUES ('from turso via magnus')", ())
            .await
            .map_err(se)?;
        let mut rows = conn.query("SELECT x FROM t", ()).await.map_err(se)?;
        let val: String = match rows.next().await.map_err(se)? {
            Some(row) => row.get(0).map_err(se)?,
            None => "NO ROWS".to_string(),
        };
        Ok::<String, Error>(val)
    })
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("TursoSpike")?;
    module.define_singleton_method("ping", function!(ping, 0))?;
    Ok(())
}
