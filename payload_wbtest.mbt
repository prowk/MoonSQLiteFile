///|
fn Database::cell_payload(
  self : Database,
  page_bytes : Bytes,
  offset : Int,
  payload_size : Int,
  table_leaf : Bool,
) -> Bytes raise SqliteError {
  self.cell_payload_tracked(
    page_bytes,
    offset,
    payload_size,
    table_leaf,
    Map([]),
  )
}

///|
test "SQLite payload distribution thresholds" {
  assert_eq(local_payload_size(477, 512, true), 477)
  assert_eq(local_payload_size(478, 512, true), 39)
  assert_eq(local_payload_size(548, 512, true), 40)
  assert_eq(local_payload_size(102, 512, false), 102)
  assert_eq(local_payload_size(103, 512, false), 39)
}

///|
test "overflow links enforce bounds cycles and resource limits" {
  let overflow : Array[Byte] = Array::make(512, 0)
  // 第二页回指自身，读取超出一页时必须报告环。
  overflow[3] = 2
  let db = open_database(test_database() + Bytes::from_array(overflow))
  let cell = Bytes::make(39, 1) + b"\x00\x00\x00\x02" + Bytes::make(469, 0)
  let failed = try {
    let _ = db.cell_payload(cell, 0, 1000, true)
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  let db = open_database(test_database(), limits={
    max_rows: 10,
    max_payload_bytes: 10,
    max_pages: 10,
    max_depth: 10,
  })
  let failed = try {
    let _ = db.cell_payload(b"", 0, 11, true)
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
// 既有白盒样本通过同一个增量 payload 解析器供页，继续验证实际生产逻辑。
fn Database::cell_payload_tracked(
  self : Database,
  bytes : Bytes,
  offset : Int,
  size : Int,
  table : Bool,
  occupied : Map[Int, PageUse],
) -> Bytes raise SqliteError {
  let reader = self.payload_reader(
    bytes,
    offset,
    size,
    table,
    occupied,
    0,
    quiet_observer(),
  )
  while reader.next_page() is Some(number) {
    reader.provide(self.read_page(number))
  }
  reader.bytes()
}
