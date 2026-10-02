///|
pub(all) struct Limits {
  max_rows : Int
  max_payload_bytes : Int
  max_pages : Int
  max_depth : Int
} derive(Debug)

///|
pub extend Limits with @debug.Debug::{to_repr}

///|
pub fn Limits::default() -> Limits {
  {
    max_rows: 100000,
    max_payload_bytes: 16777216,
    max_pages: 100000,
    max_depth: 64,
  }
}

///|
pub struct Database {
  source : &PageSource
  header : Header
  page_count : Int
  limits : Limits
}

///|
pub fn open_database(
  data : Bytes,
  limits? : Limits = Limits::default(),
) -> Database raise SqliteError {
  open_source(BytesSource::new(data), limits~)
}

///|
pub fn Database::header(self : Database) -> Header {
  self.header
}

///|
pub fn Database::page_count(self : Database) -> Int {
  self.page_count
}

///|
pub fn Database::read_page(
  self : Database,
  number : Int,
) -> Bytes raise SqliteError {
  if number < 1 || number > self.page_count {
    raise Invalid("页号越界：\{number}")
  }
  let offset = (number - 1) * self.header.page_size
  source_read(self.source, offset, self.header.page_size)
}

///|
fn page_number(value : UInt) -> Int raise SqliteError {
  bounded_int(value.to_uint64(), "page number")
}
