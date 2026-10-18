//! Process-wide statement locks, one per database file.
//!
//! The engine reports overlapping autocommit writers on one file as busy, so
//! statements on a file must never overlap. A lock per [`Database`] is not
//! enough: callers such as an ActiveRecord pool open one `Database` per pooled
//! connection, all on the same file. [`for_path`] therefore hands every
//! `Database` opened on the same file (after canonicalising its path) the same
//! [`StmtLock`]. In-memory databases are private to their `Database`, so each
//! gets its own lock.
//!
//! [`Database`]: crate::Database

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::Duration;

use crate::{Error, Result};

/// How often a waiter that can be interrupted checks its flag.
const INTERRUPT_POLL: Duration = Duration::from_millis(5);

/// A lock held for exactly one statement. A `Mutex<bool>` plus `Condvar`
/// rather than a plain `Mutex<()>`, so a waiter can give up when its
/// interrupt flag is set (see [`StmtLock::acquire`]).
#[derive(Default)]
pub(crate) struct StmtLock {
    locked: Mutex<bool>,
    released: Condvar,
}

/// Releases the [`StmtLock`] on drop.
pub(crate) struct StmtGuard<'a>(&'a StmtLock);

impl StmtLock {
    /// Waits for the lock. With `interrupt`, returns [`Error::Interrupted`]
    /// as soon as the flag is set while still waiting; a lock already taken
    /// is never given up.
    pub(crate) fn acquire(&self, interrupt: Option<&AtomicBool>) -> Result<StmtGuard<'_>> {
        let mut locked = self.locked.lock().unwrap_or_else(|p| p.into_inner());
        while *locked {
            locked = match interrupt {
                Some(flag) => {
                    if flag.load(Ordering::Acquire) {
                        return Err(Error::Interrupted);
                    }
                    self.released
                        .wait_timeout(locked, INTERRUPT_POLL)
                        .unwrap_or_else(|p| p.into_inner())
                        .0
                }
                None => self
                    .released
                    .wait(locked)
                    .unwrap_or_else(|p| p.into_inner()),
            };
        }
        *locked = true;
        Ok(StmtGuard(self))
    }
}

impl Drop for StmtGuard<'_> {
    fn drop(&mut self) {
        *self.0.locked.lock().unwrap_or_else(|p| p.into_inner()) = false;
        self.0.released.notify_one();
    }
}

/// The lock shared by every `Database` in this process opened on `path`.
pub(crate) fn for_path(path: &str) -> Arc<StmtLock> {
    if path.is_empty() || path == ":memory:" {
        return Arc::default();
    }
    let key = canonical(Path::new(path));
    let mut locks = registry().locks.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(lock) = locks.get(&key).and_then(Weak::upgrade) {
        return lock;
    }
    // Drop entries whose databases have all gone, so the map stays small.
    locks.retain(|_, w| w.strong_count() > 0);
    let lock = Arc::<StmtLock>::default();
    locks.insert(key, Arc::downgrade(&lock));
    lock
}

/// The file's canonical path: called after a successful open, so the file
/// exists. Falls back to an absolute path, then to the path as given.
fn canonical(path: &Path) -> PathBuf {
    std::fs::canonicalize(path)
        .or_else(|_| std::path::absolute(path))
        .unwrap_or_else(|_| path.to_path_buf())
}

struct Registry {
    pid: u32,
    locks: Mutex<HashMap<PathBuf, Weak<StmtLock>>>,
}

static REGISTRY: AtomicPtr<Registry> = AtomicPtr::new(ptr::null_mut());

/// This process's registry. A forked child gets a fresh one and leaks the
/// parent's, whose mutex a parent thread may have held at fork time, leaving
/// it locked with no owner in the child.
fn registry() -> &'static Registry {
    let pid = std::process::id();
    loop {
        let current = REGISTRY.load(Ordering::Acquire);
        // SAFETY: a registry, once published, is never freed.
        if let Some(reg) = unsafe { current.as_ref() } {
            if reg.pid == pid {
                return reg;
            }
        }
        let fresh = Box::into_raw(Box::new(Registry {
            pid,
            locks: Mutex::default(),
        }));
        match REGISTRY.compare_exchange(current, fresh, Ordering::AcqRel, Ordering::Acquire) {
            // SAFETY: just published; never freed.
            Ok(_) => return unsafe { &*fresh },
            // Another thread published first; ours was never shared.
            Err(_) => drop(unsafe { Box::from_raw(fresh) }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    fn temp_file(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "btc_stmtlock_{name}_{}_{:?}",
            std::process::id(),
            Instant::now()
        ));
        std::fs::write(&path, b"").unwrap();
        path
    }

    #[test]
    fn same_file_shares_one_lock_however_it_is_spelled() {
        let path = temp_file("same");
        let dir = path.parent().unwrap();
        let name = path.file_name().unwrap().to_str().unwrap();
        let a = for_path(path.to_str().unwrap());
        let b = for_path(dir.join(".").join(name).to_str().unwrap());
        assert!(Arc::ptr_eq(&a, &b));
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn different_files_and_in_memory_databases_get_their_own_locks() {
        let (p1, p2) = (temp_file("one"), temp_file("two"));
        let a = for_path(p1.to_str().unwrap());
        let b = for_path(p2.to_str().unwrap());
        assert!(!Arc::ptr_eq(&a, &b));
        assert!(!Arc::ptr_eq(&for_path(":memory:"), &for_path(":memory:")));
        std::fs::remove_file(p1).unwrap();
        std::fs::remove_file(p2).unwrap();
    }

    #[test]
    fn a_lock_outlives_its_registry_entry_only_while_in_use() {
        let path = temp_file("weak");
        let p = path.to_str().unwrap();
        let first = for_path(p);
        let addr = Arc::as_ptr(&first);
        assert_eq!(Arc::as_ptr(&for_path(p)), addr);
        drop(first);
        // Every holder gone: the next open starts a fresh lock.
        let again = for_path(p);
        assert_eq!(Arc::strong_count(&again), 1);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn a_waiter_gives_up_when_interrupted_but_a_holder_never_does() {
        let lock = StmtLock::default();
        let held = lock.acquire(None).unwrap();
        let flag = AtomicBool::new(false);
        std::thread::scope(|s| {
            let waiter = s.spawn(|| lock.acquire(Some(&flag)).map(|_| ()));
            std::thread::sleep(Duration::from_millis(50));
            flag.store(true, Ordering::Release);
            let r = waiter.join().unwrap();
            assert!(matches!(r, Err(Error::Interrupted)), "got {r:?}");
        });
        // A set flag doesn't matter once the lock is free.
        drop(held);
        assert!(lock.acquire(Some(&flag)).is_ok());
    }

    #[test]
    fn release_wakes_the_next_waiter() {
        let lock = StmtLock::default();
        let held = lock.acquire(None).unwrap();
        std::thread::scope(|s| {
            let waiter = s.spawn(|| {
                let t0 = Instant::now();
                let _g = lock.acquire(None).unwrap();
                t0.elapsed()
            });
            std::thread::sleep(Duration::from_millis(50));
            drop(held);
            assert!(waiter.join().unwrap() >= Duration::from_millis(40));
        });
    }
}
