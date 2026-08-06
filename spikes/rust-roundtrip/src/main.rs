// Spike 1: prove the new Turso engine's local-first sync round-trips.
//
// A writes locally -> push() to Turso Cloud. A fresh replica B bootstraps/pull()s
// from the cloud and must see A's write. If B sees this run's unique marker, the
// engine-driven local-first + push/pull model (hero A) is real.
//
// Creds come from the environment (.env sourced by the runner): never hard-coded.

use std::time::{SystemTime, UNIX_EPOCH};
use turso::sync::Builder;

async fn open(path: &str) -> anyhow::Result<turso::sync::Database> {
    let db = Builder::new_remote(path)
        .with_remote_url(&std::env::var("TURSO_DATABASE_URL")?)
        .with_auth_token(&std::env::var("TURSO_AUTH_TOKEN")?)
        .bootstrap_if_empty(true)
        .build()
        .await?;
    Ok(db)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Unique per-run marker so we prove THIS run's write round-tripped,
    // not leftover data from a previous run.
    let marker = format!(
        "spike-{}",
        SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()
    );
    println!("marker = {marker}");

    // --- Replica A: write locally, push to cloud ---
    let db_a = open("spike_a.db").await?;
    let conn_a = db_a.connect().await?;
    conn_a
        .execute(
            "CREATE TABLE IF NOT EXISTS spike (id INTEGER PRIMARY KEY, name TEXT)",
            (),
        )
        .await?;
    conn_a
        .execute(&format!("INSERT INTO spike (name) VALUES ('{marker}')"), ())
        .await?;
    println!("A: inserted marker locally");
    db_a.push().await?;
    println!("A: push() -> cloud OK");

    // --- Replica B: fresh local file, bootstrap/pull from cloud, must see marker ---
    let db_b = open("spike_b.db").await?;
    let pulled = db_b.pull().await?;
    println!("B: pull() returned {pulled:?}");
    let conn_b = db_b.connect().await?;
    let mut rows = conn_b
        .query(
            &format!("SELECT count(*) FROM spike WHERE name = '{marker}'"),
            (),
        )
        .await?;
    let count: i64 = match rows.next().await? {
        Some(row) => row.get(0)?,
        None => 0,
    };
    println!("B: rows matching this run's marker = {count}");

    if count == 1 {
        println!("SPIKE1 PASS: local-first write round-tripped A -> cloud -> B");
        Ok(())
    } else {
        anyhow::bail!("SPIKE1 FAIL: marker not found in replica B (count={count})");
    }
}
