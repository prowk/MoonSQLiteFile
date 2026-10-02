///|
test "real SQLite schema including interior page one" {
  let db = open_database(fixture_core())
  assert_eq(db.header().page_size, 512)
  assert_eq(db.page_count(), 96)
  assert_eq(db.page(1).kind, TableInterior)
  let schema = db.schema()
  assert_eq(schema.length(), 5)
  assert_eq(schema[0].name, "samples")
  assert_eq(schema[0].root_page, 2)
  assert_eq(schema[3].name, "keyed")
  assert_eq(db.page(schema[3].root_page).kind, IndexLeaf)
  let failed = try {
    let _ = db.table_rows("keyed")
    false
  } catch {
    Unsupported(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "real SQLite rowid and storage values" {
  let rows = open_database(fixture_core()).table_rows("samples")
  assert_eq(rows.length(), 6)
  assert_eq(rows[0].rowid, -7L)
  // INTEGER PRIMARY KEY 的磁盘字段为空，真实主键值保存在 rowid。
  assert_eq(rows[0].values, [
    Null,
    Text("中文 SQLite 🌙"),
    Integer(-9223372036854775808L),
    Real(-1.25),
    Blob(b"\x00\xff\x10\x41\x80"),
    Null,
  ])
  assert_eq(rows[5].rowid, 16384L)
  assert_eq(rows[5].values[2], Integer(9223372036854775807L))
}

///|
test "three level b-tree preserves all 680 rows" {
  let db = open_database(fixture_core())
  assert_eq(db.page(3).kind, TableInterior)
  let rows = db.table_rows("branches")
  assert_eq(rows.length(), 680)
  for i = 0; i < rows.length(); i = i + 1 {
    assert_eq(rows[i].rowid, (i + 1).to_int64())
  }
  assert_eq(
    rows[0].values[1],
    Text("row-0001-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"),
  )
  assert_eq(db.table_rows("branches", limit=7).length(), 7)
}

///|
test "overflow chains reconstruct Unicode and blobs" {
  let rows = open_database(fixture_core()).table_rows("overflow_data")
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].values[1], Text("月亮🌙".repeat(400)))
  let expected = Bytes::makei(2048, i => (i % 256).to_byte())
  assert_eq(rows[0].values[2], Blob(expected))
}

///|
test "UTF16 both byte orders and 65536 byte pages" {
  for data in [fixture_utf16le(), fixture_utf16be()] {
    let db = open_database(data)
    let rows = db.table_rows("words")
    assert_eq(rows.length(), 3)
    assert_eq(rows[0].values[1], Text("中文🌙"))
    assert_eq(rows[1].values[1], Text("AéΩ𐐷"))
    assert_eq(rows[2].values[1], Text(""))
  }
  let db = open_database(fixture_page65536())
  assert_eq(db.header().page_size, 65536)
  assert_eq(db.page_count(), 2)
  assert_eq(db.schema().length(), 1)
  assert_eq(open_database(fixture_empty()).schema().length(), 0)
}

///|
test "real freelist and traversal resource limits" {
  let bytes = fixture_core()
  let db = open_database(bytes)
  assert_eq(db.freelist().length(), 7)
  let limited = open_database(bytes, limits={
    max_rows: 10,
    max_payload_bytes: 100,
    max_pages: 100,
    max_depth: 2,
  })
  let failed = try {
    let _ = limited.read_table(3)
    false
  } catch {
    LimitExceeded(_) => true
    _ => false
  }
  assert_true(failed)
  let failed = try {
    let _ = limited.read_table(74)
    false
  } catch {
    LimitExceeded(_) => true
    _ => false
  }
  assert_true(failed)
}
