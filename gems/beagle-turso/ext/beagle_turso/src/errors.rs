// Maps beagle_turso_core errors onto the Ruby hierarchy defined in
// lib/beagle/turso/errors.rb. Classes are looked up by name at raise time
// (the error path only), so the Ruby file stays the single definition.

use beagle_turso_core::Error as CoreError;
use magnus::{exception::ExceptionClass, prelude::*, Error, RModule, Ruby};

pub fn error_class(ruby: &Ruby, name: &str) -> ExceptionClass {
    ruby.class_object()
        .const_get::<_, RModule>("Beagle")
        .and_then(|m| m.const_get::<_, RModule>("Turso"))
        .and_then(|m| m.const_get::<_, ExceptionClass>(name))
        .unwrap_or_else(|_| ruby.exception_runtime_error())
}

pub fn raise_core(ruby: &Ruby, e: CoreError) -> Error {
    let name = match &e {
        CoreError::Open(_) => "OpenError",
        CoreError::Connect(_) => "ConnectError",
        CoreError::Query(_) => "QueryError",
        CoreError::Sync(_) => "SyncError",
        CoreError::NotSynced(_) => "NotSyncedError",
        CoreError::Busy(_) => "BusyError",
        CoreError::Closed => "ClosedError",
        CoreError::Forked { .. } => "ForkedError",
        // Never raised: run_statement retries an interrupted wait, or Ruby
        // raises its pending interrupt instead. The base class, to be safe.
        CoreError::Interrupted => "Error",
        // Value conversion problems stay Ruby's TypeError, as in 0.1.x.
        CoreError::Type(_) => return Error::new(ruby.exception_type_error(), e.to_string()),
    };
    Error::new(error_class(ruby, name), e.to_string())
}
