#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Integer(i64),
    Real(f64),
    Text(String),
    Blob(Vec<u8>),
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
