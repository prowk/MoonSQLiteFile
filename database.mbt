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
  data : Bytes
  header : Header
  page_count : Int
  limits : Limits
}

///|
pub fn open_database(
  data : Bytes,
  limits? : Limits = Limits::default(),
) -> Database raise SqliteError {
  if limits.max_rows < 1 ||
    limits.max_payload_bytes < 1 ||
    limits.max_pages < 1 ||
    limits.max_depth < 1 {
    raise Invalid("所有资源限制必须为正数")
  }
  let header = parse_header(data)
  if data.length() % header.page_size != 0 || data.length() < header.page_size {
    raise Invalid("数据库文件不包含完整页面")
  }
  let physical_pages = data.length() / header.page_size
  // 仅在版本计数一致时信任数据库头中的页数，兼容旧版 SQLite。
  let page_count = if header.declared_pages != 0U &&
    header.change_counter == header.version_valid_for {
    let declared = bounded_int(
      header.declared_pages.to_uint64(),
      "database pages",
    )
    if declared > physical_pages {
      raise Invalid(
        "数据库声明页数超过文件长度；请使用 checkpoint 后的副本",
      )
    }
    declared
  } else {
    physical_pages
  }
  if header.freelist_pages.to_uint64() > page_count.to_uint64() {
    raise Invalid("freelist 页数超过数据库页数")
  }
  { data, header, page_count, limits, }
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
  self.data[offset:offset + self.header.page_size].to_owned()
}

///|
fn page_number(value : UInt) -> Int raise SqliteError {
  bounded_int(value.to_uint64(), "page number")
}
