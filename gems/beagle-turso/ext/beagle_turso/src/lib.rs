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

use beagle_turso_core::{Connection, Database, OpenOptions, Value};
use magnus::{function, method, prelude::*, Error, Float, IntoValue, Integer, RArray, RString, Ruby};

#[magnus::wrap(class = "Beagle::Turso::Database", free_immediately)]
struct RbDatabase {
    inner: Database,
}

#[magnus::wrap(class = "Beagle::Turso::Connection", free_immediately)]
struct RbConnection {
    inner: Connection,
}

fn rt_err(ruby: &Ruby, msg: String) -> Error {
    Error::new(ruby.exception_runtime_error(), msg)
}

fn ruby_array_to_params(ruby: &Ruby, arr: RArray) -> Result<Vec<Value>, Error> {
    // Safe: `from_value` below is a raw type check on the Ruby object (exact
    // class match — no `to_int`/`to_f`/`to_str` coercion method dispatch), so
    // for the sanctioned nil/Integer/Float/String inputs no arbitrary Ruby
    // code (which could GC/mutate the array) runs during this loop; an
    // unsupported type falls straight to the `else` arm without invoking any
    // Ruby method at all.
    let items = unsafe { arr.as_slice() };
    let mut out = Vec::with_capacity(items.len());
    for &item in items {
        let v = if item.is_nil() {
            Value::Null
        } else if let Some(i) = Integer::from_value(item) {
            Value::Integer(i.to_i64()?)
        } else if let Some(f) = Float::from_value(item) {
            Value::Real(f.to_f64())
        } else if let Some(s) = RString::from_value(item) {
            Value::Text(s.to_string()?)
        } else {
            return Err(Error::new(ruby.exception_type_error(), "unsupported bind parameter type"));
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
        let db = Database::open(opts).map_err(|e| rt_err(ruby, e.to_string()))?;
        Ok(RbDatabase { inner: db })
    }

    fn connect(ruby: &Ruby, rb_self: &Self) -> Result<RbConnection, Error> {
        let c = rb_self.inner.connect().map_err(|e| rt_err(ruby, e.to_string()))?;
        Ok(RbConnection { inner: c })
    }
}

impl RbConnection {
    fn execute(ruby: &Ruby, rb_self: &Self, sql: String, params: RArray) -> Result<u64, Error> {
        let p = ruby_array_to_params(ruby, params)?;
        rb_self.inner.execute(&sql, &p).map_err(|e| rt_err(ruby, e.to_string()))
    }

    fn query(ruby: &Ruby, rb_self: &Self, sql: String, params: RArray) -> Result<RArray, Error> {
        let p = ruby_array_to_params(ruby, params)?;
        let rows = rb_self.inner.query(&sql, &p).map_err(|e| rt_err(ruby, e.to_string()))?;
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
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let turso = ruby.define_module("Beagle")?.define_module("Turso")?;
    let db = turso.define_class("Database", ruby.class_object())?;
    db.define_singleton_method("open_local", function!(RbDatabase::open_local, 1))?;
    db.define_method("connect", method!(RbDatabase::connect, 0))?;
    let conn = turso.define_class("Connection", ruby.class_object())?;
    conn.define_method("execute", method!(RbConnection::execute, 2))?;
    conn.define_method("query", method!(RbConnection::query, 2))?;
    Ok(())
}
