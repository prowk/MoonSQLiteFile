///|
fn main {
  // 构造 SQLite 的空数据库快照；实际应用从宿主读取文件后传入 Bytes。
  let header = b"SQLite format 3\x00\x02\x00\x01\x01\x00\x40\x20\x20" +
    Bytes::make(76, 0)
  let data = header + b"\x0d\x00\x00\x00\x00\x02\x00\x00" + Bytes::make(404, 0)
  try {
    let db = @sqlite.open_database(data)
    println("page_size=\{db.header().page_size}, pages=\{db.page_count()}")
    println("schema entries=\{db.schema().length()}")
  } catch {
    @sqlite.Invalid(message)
    | @sqlite.Unsupported(message)
    | @sqlite.LimitExceeded(message) => println("读取失败：\{message}")
  }
}
