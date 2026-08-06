use magnus::{prelude::*, Error, Ruby};

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let turso = ruby.define_module("Beagle")?.define_module("Turso")?;
    turso.define_class("Database", ruby.class_object())?;
    Ok(())
}
