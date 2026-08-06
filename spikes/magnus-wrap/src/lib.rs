// Plan 2 spike P2b: full binding proof.
// Wrap BOTH Database and Connection as persistent Ruby objects, and prove a real
// round-trip (open -> connect -> execute -> query) across SEPARATE Ruby method
// calls, with Ruby<->core Value conversion. If this compiles + passes, the whole
// Plan 2 binding approach (direct #[magnus::wrap], no actor thread) is proven.

use beagle_turso_core::{Connection, Database, OpenOptions, Value};
use magnus::{function, method, prelude::*, Error, IntoValue, RArray, Ruby, TryConvert};

#[magnus::wrap(class = "Beagle::Turso::Database", free_immediately)]
struct RbDatabase {
    inner: Database,
}

#[magnus::wrap(class = "Beagle::Turso::Connection", free_immediately)]
struct RbConnection {
    inner: Connection,
}

fn rt_err(msg: String) -> Error {
    Error::new(magnus::exception::runtime_error(), msg)
}

fn ruby_array_to_params(arr: RArray) -> Result<Vec<Value>, Error> {
    // Safe here: no Ruby code (which could GC/mutate the array) runs during this loop.
    let items = unsafe { arr.as_slice() };
    let mut out = Vec::with_capacity(items.len());
    for &item in items {
        let v = if item.is_nil() {
            Value::Null
        } else if let Ok(i) = i64::try_convert(item) {
            Value::Integer(i)
        } else if let Ok(f) = f64::try_convert(item) {
            Value::Real(f)
        } else if let Ok(s) = String::try_convert(item) {
            Value::Text(s)
        } else {
            return Err(Error::new(
                magnus::exception::type_error(),
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
    fn open_local(path: String) -> Result<RbDatabase, Error> {
        let opts = OpenOptions {
            local_path: path,
            remote_url: None,
            auth_token: None,
            bootstrap_if_empty: true,
        };
        let db = Database::open(opts).map_err(|e| rt_err(e.to_string()))?;
        Ok(RbDatabase { inner: db })
    }

    fn connect(&self) -> Result<RbConnection, Error> {
        let c = self.inner.connect().map_err(|e| rt_err(e.to_string()))?;
        Ok(RbConnection { inner: c })
    }
}

impl RbConnection {
    fn execute(&self, sql: String, params: RArray) -> Result<u64, Error> {
        let p = ruby_array_to_params(params)?;
        self.inner.execute(&sql, &p).map_err(|e| rt_err(e.to_string()))
    }

    fn query(&self, sql: String, params: RArray) -> Result<RArray, Error> {
        let ruby = Ruby::get().map_err(|_| rt_err("Ruby unavailable".into()))?;
        let p = ruby_array_to_params(params)?;
        let rows = self.inner.query(&sql, &p).map_err(|e| rt_err(e.to_string()))?;
        let out = ruby.ary_new();
        for row in rows {
            let rb_row = ruby.ary_new();
            for val in &row.values {
                rb_row.push(value_to_ruby(&ruby, val))?;
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
