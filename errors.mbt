///|
pub suberror SqliteError {
  Invalid(String)
  Unsupported(String)
  LimitExceeded(String)
} derive(Debug)
