///|
pub suberror SqliteError {
  Invalid(String)
  Unsupported(String)
  LimitExceeded(String)
} derive(Debug)

///|
pub extend SqliteError with @debug.Debug::{to_repr}
