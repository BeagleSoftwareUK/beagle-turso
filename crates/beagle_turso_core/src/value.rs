#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Integer(i64),
    Real(f64),
    Text(String),
    Blob(Vec<u8>),
}

impl Value {
    /// Our Value -> the engine's parameter value.
    pub(crate) fn to_turso(&self) -> turso::Value {
        match self {
            Value::Null => turso::Value::Null,
            Value::Integer(i) => turso::Value::Integer(*i),
            Value::Real(f) => turso::Value::Real(*f),
            Value::Text(s) => turso::Value::Text(s.clone()),
            Value::Blob(b) => turso::Value::Blob(b.clone()),
        }
    }

    /// The engine's column value -> our Value.
    pub(crate) fn from_turso(v: turso::Value) -> Value {
        match v {
            turso::Value::Null => Value::Null,
            turso::Value::Integer(i) => Value::Integer(i),
            turso::Value::Real(f) => Value::Real(f),
            turso::Value::Text(s) => Value::Text(s),
            turso::Value::Blob(b) => Value::Blob(b),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Value;

    #[test]
    fn value_equality_and_clone() {
        let v = Value::Text("hi".into());
        assert_eq!(v.clone(), Value::Text("hi".into()));
        assert_ne!(Value::Integer(1), Value::Integer(2));
        assert_eq!(Value::Null, Value::Null);
    }
}
