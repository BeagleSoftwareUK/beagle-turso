// Wraps beagle_turso_core's Database and Connection as persistent Ruby
// objects, exposing a synchronous open -> connect -> execute -> query API.
// Lifted from the proven spike at spikes/magnus-wrap/src/lib.rs (Plan 2's
// binding proof).
//
// One deliberate deviation from the spike: each wrapped fn/method takes
// `ruby: &Ruby` as its leading parameter (magnus's `function!`/`method!`
// macros inject it automatically — see the magnus 0.8 README's "Error
// Handling" example) instead of calling the fallible `Ruby::get()` inside
// the body. That sidesteps the "Ruby unavailable" fallback branch, which
// has no live `&Ruby` to call the non-deprecated `Ruby::exception_*`
// accessors on and so would otherwise need the deprecated
// `magnus::exception::standard_error()` free function. Net effect is
// identical; the code is simpler and compiles with zero deprecation
// warnings.

// GVL: open_local, open, connect, push and pull, and the five statement
// methods (execute, query, query_result, query_result_with_types,
// execute_batch) run via nogvl::without_gvl with the GVL released, so other
// threads run and a worker-pool fiber scheduler offloads them off its reactor.
// Statement params are converted to core values before the call and Ruby rows
// built after it; the closure touches no Ruby object. The core serialises
// statements per database file (its statement lock, shared by every Database
// in the process opened on that file), so releasing the GVL adds no new write
// overlap. `Beagle::Turso.statement_gvl = :hold` (or
// BEAGLE_TURSO_STATEMENT_GVL=hold at load) runs statements under the GVL
// instead, as in 0.3.0. last_insert_rowid, close and closed? stay under the
// GVL: they are cheap.

mod errors;
mod nogvl;

use std::sync::atomic::{AtomicBool, Ordering};

use beagle_turso_core::{Connection, Database, Error as CoreError, OpenOptions, Value};
use errors::raise_core;
use nogvl::{without_gvl, without_gvl_interruptible};
use magnus::{
    encoding::EncodingCapable, function, method, prelude::*, Error, Float, Integer, IntoValue,
    RArray, RString, Ruby,
};

// Process-wide: true runs statements with the GVL held (`statement_gvl :hold`).
static HOLD_STATEMENT_GVL: AtomicBool = AtomicBool::new(false);

fn set_statement_gvl_hold(hold: bool) {
    HOLD_STATEMENT_GVL.store(hold, Ordering::Relaxed);
}

fn statement_gvl_hold() -> bool {
    HOLD_STATEMENT_GVL.load(Ordering::Relaxed)
}

// Never set: the interrupt flag for statements run under the GVL.
static NEVER_INTERRUPTED: AtomicBool = AtomicBool::new(false);

// Runs one statement: without the GVL by default, or directly under it when
// the switch is `:hold`. `f` must touch no Ruby object; it returns the core
// Result, which the caller maps to a Ruby exception once the GVL is back.
//
// Without the GVL, `f` gets the flag Ruby's unblocking function sets, so
// Thread#raise/kill and Timeout stop a statement still waiting for another on
// the same file (the core returns Interrupted; one already running finishes).
// Ruby then raises its pending exception from without_gvl_interruptible. If it
// has none to raise (a trap handler ran, say), the statement waits again.
fn run_statement<F, R>(mut f: F) -> Result<Result<R, CoreError>, Error>
where
    F: FnMut(&AtomicBool) -> Result<R, CoreError> + Send,
    R: Send,
{
    if statement_gvl_hold() {
        return Ok(f(&NEVER_INTERRUPTED));
    }
    loop {
        match without_gvl_interruptible(|flag| f(flag))? {
            Err(CoreError::Interrupted) => continue,
            done => return Ok(done),
        }
    }
}

#[magnus::wrap(class = "Beagle::Turso::Database", free_immediately)]
struct RbDatabase {
    inner: Database,
}

#[magnus::wrap(class = "Beagle::Turso::Connection", free_immediately)]
struct RbConnection {
    inner: Connection,
}

fn ruby_array_to_params(ruby: &Ruby, arr: RArray) -> Result<Vec<Value>, Error> {
    // Safe: `from_value` below is a raw type check on the Ruby object (exact
    // class match — no `to_int`/`to_f`/`to_str` coercion method dispatch), so
    // for the sanctioned nil/Integer/Float/String inputs no arbitrary Ruby
    // code (which could GC/mutate the array) runs during this loop; an
    // unsupported type falls straight to the `else` arm without invoking any
    // Ruby method at all. The binary/text split below on an `RString` is
    // likewise native: `EncodingCapable::enc_get` is a direct
    // `rb_enc_get_index` C call (no method dispatch). For the binary branch
    // `as_slice` is copied into an owned `Vec` immediately, before any
    // further Ruby call in this loop iteration, so the borrow never outlives
    // a point where the backing string could be mutated/GC'd out from under
    // it.
    let items = unsafe { arr.as_slice() };
    let ascii_8bit = ruby.ascii8bit_encindex();
    let mut out = Vec::with_capacity(items.len());
    for &item in items {
        let v = if item.is_nil() {
            Value::Null
        } else if let Some(i) = Integer::from_value(item) {
            Value::Integer(i.to_i64()?)
        } else if let Some(f) = Float::from_value(item) {
            Value::Real(f.to_f64())
        } else if let Some(s) = RString::from_value(item) {
            if s.enc_get() == ascii_8bit {
                Value::Blob(unsafe { s.as_slice() }.to_vec())
            } else {
                Value::Text(s.to_string()?)
            }
        } else {
            return Err(Error::new(
                ruby.exception_type_error(),
                "unsupported bind parameter type",
            ));
        };
        out.push(v);
    }
    Ok(out)
}

fn value_to_ruby(ruby: &Ruby, v: &Value) -> magnus::Value {
    match v {
        Value::Null => ruby.qnil().as_value(),
        Value::Integer(i) => (*i).into_value_with(ruby),
        Value::Real(f) => (*f).into_value_with(ruby),
        Value::Text(s) => s.clone().into_value_with(ruby),
        Value::Blob(b) => ruby.str_from_slice(b).as_value(),
    }
}

impl RbDatabase {
    fn open_local(ruby: &Ruby, path: String) -> Result<RbDatabase, Error> {
        let opts = OpenOptions {
            local_path: path,
            remote_url: None,
            auth_token: None,
            bootstrap_if_empty: true,
        };
        let db = without_gvl(|| Database::open(opts))?.map_err(|e| raise_core(ruby, e))?;
        Ok(RbDatabase { inner: db })
    }

    // Positional primitive backing the keyword-arg `Database.open` defined in
    // Ruby (see lib/beagle/turso.rb). Kept positional so magnus can
    // TryConvert `nil`/`String`/bool natively for each argument, instead of
    // parsing an RHash of keyword args by hand in Rust.
    fn open(
        ruby: &Ruby,
        local_path: String,
        remote_url: Option<String>,
        auth_token: Option<String>,
        bootstrap_if_empty: bool,
    ) -> Result<RbDatabase, Error> {
        let opts = OpenOptions {
            local_path,
            remote_url,
            auth_token,
            bootstrap_if_empty,
        };
        let db = without_gvl(|| Database::open(opts))?.map_err(|e| raise_core(ruby, e))?;
        Ok(RbDatabase { inner: db })
    }

    fn connect(ruby: &Ruby, rb_self: &Self) -> Result<RbConnection, Error> {
        let inner = &rb_self.inner;
        let c = without_gvl(|| inner.connect())?.map_err(|e| raise_core(ruby, e))?;
        Ok(RbConnection { inner: c })
    }

    fn push(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        let inner = &rb_self.inner;
        without_gvl(|| inner.push())?.map_err(|e| raise_core(ruby, e))
    }

    fn pull(ruby: &Ruby, rb_self: &Self) -> Result<bool, Error> {
        let inner = &rb_self.inner;
        without_gvl(|| inner.pull())?.map_err(|e| raise_core(ruby, e))
    }

    // Release the underlying engine handle and, for a synced database, end its
    // remote sync session, instead of waiting for GC. Idempotent.
    fn close(_ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        rb_self.inner.close();
        Ok(())
    }

    fn is_closed(_ruby: &Ruby, rb_self: &Self) -> bool {
        rb_self.inner.is_closed()
    }
}

fn rows_to_ruby(ruby: &Ruby, rows: Vec<beagle_turso_core::Row>) -> Result<RArray, Error> {
    let out = ruby.ary_new();
    for row in rows {
        let rb_row = ruby.ary_new();
        for val in &row.values {
            rb_row.push(value_to_ruby(ruby, val))?;
        }
        out.push(rb_row)?;
    }
    Ok(out)
}

impl RbConnection {
    fn execute(ruby: &Ruby, rb_self: &Self, sql: String, params: RArray) -> Result<u64, Error> {
        let p = ruby_array_to_params(ruby, params)?;
        let inner = &rb_self.inner;
        run_statement(|i| inner.execute_interruptible(&sql, &p, i))?
            .map_err(|e| raise_core(ruby, e))
    }

    fn query(ruby: &Ruby, rb_self: &Self, sql: String, params: RArray) -> Result<RArray, Error> {
        let p = ruby_array_to_params(ruby, params)?;
        let inner = &rb_self.inner;
        let rows = run_statement(|i| inner.query_result_interruptible(&sql, &p, i).map(|r| r.rows))?
            .map_err(|e| raise_core(ruby, e))?;
        rows_to_ruby(ruby, rows)
    }

    // Like `query`, but also returns column names — needed by callers (e.g.
    // an ActiveRecord adapter) that must know column identity, not just
    // positional values. Returns a 2-element `[columns, rows]` array;
    // `rows` is built with the same loop `query` uses.
    fn query_result(
        ruby: &Ruby,
        rb_self: &Self,
        sql: String,
        params: RArray,
    ) -> Result<RArray, Error> {
        let p = ruby_array_to_params(ruby, params)?;
        let inner = &rb_self.inner;
        let result =
            run_statement(|i| inner.query_result_interruptible(&sql, &p, i))?
                .map_err(|e| raise_core(ruby, e))?;
        let columns = ruby.ary_new();
        for name in &result.columns {
            columns.push(name.clone().into_value_with(ruby))?;
        }
        let rows = rows_to_ruby(ruby, result.rows)?;
        let out = ruby.ary_new();
        out.push(columns)?;
        out.push(rows)?;
        Ok(out)
    }

    // Like `query_result`, plus each column's declared type (String or nil),
    // which a Sequel adapter needs to pick value conversions. Returns
    // `[columns, decl_types, rows]`.
    fn query_result_with_types(
        ruby: &Ruby,
        rb_self: &Self,
        sql: String,
        params: RArray,
    ) -> Result<RArray, Error> {
        let p = ruby_array_to_params(ruby, params)?;
        let inner = &rb_self.inner;
        let result =
            run_statement(|i| inner.query_result_interruptible(&sql, &p, i))?
                .map_err(|e| raise_core(ruby, e))?;
        let columns = ruby.ary_new();
        for name in result.columns {
            columns.push(name)?;
        }
        let types = ruby.ary_new();
        for t in result.decl_types {
            types.push(t)?; // Option<String> -> String or nil
        }
        let out = ruby.ary_new();
        out.push(columns)?;
        out.push(types)?;
        out.push(rows_to_ruby(ruby, result.rows)?)?;
        Ok(out)
    }

    fn last_insert_rowid(ruby: &Ruby, rb_self: &Self) -> Result<i64, Error> {
        rb_self
            .inner
            .last_insert_rowid()
            .map_err(|e| raise_core(ruby, e))
    }

    fn execute_batch(ruby: &Ruby, rb_self: &Self, sql: String) -> Result<(), Error> {
        let inner = &rb_self.inner;
        run_statement(|i| inner.execute_batch_interruptible(&sql, i))?
            .map_err(|e| raise_core(ruby, e))
    }

    // Release the underlying connection handle instead of waiting for GC.
    // Idempotent.
    fn close(_ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        rb_self.inner.close();
        Ok(())
    }

    fn is_closed(_ruby: &Ruby, rb_self: &Self) -> bool {
        rb_self.inner.is_closed()
    }
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let turso = ruby.define_module("Beagle")?.define_module("Turso")?;
    // Back Beagle::Turso.statement_gvl / statement_gvl= (lib/beagle/turso.rb).
    turso.define_module_function(
        "_set_statement_gvl_hold",
        function!(set_statement_gvl_hold, 1),
    )?;
    turso.define_module_function("_statement_gvl_hold?", function!(statement_gvl_hold, 0))?;
    let db = turso.define_class("Database", ruby.class_object())?;
    db.define_singleton_method("open_local", function!(RbDatabase::open_local, 1))?;
    // Positional primitive; the public keyword-arg `Database.open` wrapper
    // lives in Ruby (lib/beagle/turso.rb) and delegates here.
    db.define_singleton_method("_open", function!(RbDatabase::open, 4))?;
    db.define_method("connect", method!(RbDatabase::connect, 0))?;
    db.define_method("push", method!(RbDatabase::push, 0))?;
    db.define_method("pull", method!(RbDatabase::pull, 0))?;
    db.define_method("close", method!(RbDatabase::close, 0))?;
    db.define_method("closed?", method!(RbDatabase::is_closed, 0))?;
    let conn = turso.define_class("Connection", ruby.class_object())?;
    conn.define_method("execute", method!(RbConnection::execute, 2))?;
    conn.define_method("query", method!(RbConnection::query, 2))?;
    conn.define_method("query_result", method!(RbConnection::query_result, 2))?;
    conn.define_method(
        "query_result_with_types",
        method!(RbConnection::query_result_with_types, 2),
    )?;
    conn.define_method(
        "last_insert_rowid",
        method!(RbConnection::last_insert_rowid, 0),
    )?;
    conn.define_method("execute_batch", method!(RbConnection::execute_batch, 1))?;
    conn.define_method("close", method!(RbConnection::close, 0))?;
    conn.define_method("closed?", method!(RbConnection::is_closed, 0))?;
    Ok(())
}
