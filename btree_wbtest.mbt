///|
test "index interior records and WITHOUT ROWID physical column order" {
  let db = open_database(fixture_btree())
  let records = db.index_records("mixed_index")
  assert_eq(records.length(), 600)
  let mut interior = 0
  for record in records {
    assert_eq(record.rowid, None)
    assert_eq(record.values.length(), 4)
    if db.page(record.page_number).kind == IndexInterior {
      interior = interior + 1
    }
  }
  assert_true(interior > 0)
  let keyed = db.table_records("keyed")
  assert_eq(keyed.length(), 96)
  assert_eq(keyed[0].rowid, None)
  assert_eq(keyed[0].values.length(), 5)
  // 声明中的 payload 在第一列，磁盘记录则以复合主键 k1、k2 开头。
  assert_true(
    match keyed[0].values[0] {
      Text(text) => text.has_prefix("GROUP") || text.has_prefix("group")
      _ => false
    },
  )
  assert_true(
    match keyed[0].values[1] {
      Integer(_) => true
      _ => false
    },
  )
  let long_keys = db.index_records("long_key_index")
  assert_eq(long_keys.length(), 24)
  assert_eq(long_keys[0].values[1], Integer(24L))
  assert_eq(db.table_records("plain")[0].rowid, Some(-7L))
}

///|
test "streaming reports exact completion limit and visitor stop" {
  let db = open_database(fixture_btree())
  let root = db.schema().filter(entry => entry.name == "mixed_index")[0].root_page
  let mut count = 0
  let summary = db.scan_btree(
    root,
    _ => {
      count = count + 1
      true
    },
    limit=600,
  )
  assert_eq(count, 600)
  assert_eq(summary.records_read, 600)
  assert_eq(summary.completion, Complete)
  assert_true(summary.pages_read > 1)
  assert_true(summary.payload_bytes > 0UL)
  let summary = db.scan_btree(root, _ => true, limit=7)
  assert_eq(summary.records_read, 7)
  assert_eq(summary.completion, RecordLimit)
  let summary = db.scan_btree(root, _ => false)
  assert_eq(summary.records_read, 1)
  assert_eq(summary.completion, VisitorStopped)
  assert_eq(db.scan_btree(root, _ => true, limit=0).completion, RecordLimit)
  assert_eq(
    open_database(test_database()).scan_btree(1, _ => true, limit=0).completion,
    Complete,
  )
}

///|
test "aggregate payload and page budgets include overflow" {
  let db = open_database(fixture_btree())
  let root = db.schema().filter(entry => entry.name == "long_key_index")[0].root_page
  let failed = try {
    let _ = db.scan_btree(root, _ => true, max_total_payload_bytes=1500UL)
    false
  } catch {
    LimitExceeded(_) => true
    _ => false
  }
  assert_true(failed)
  let failed = try {
    let _ = db.scan_btree(root, _ => true, max_total_payload_bytes=0UL)
    false
  } catch {
    LimitExceeded(_) => true
    _ => false
  }
  assert_true(failed)
  let limited = open_database(fixture_btree(), limits={
    max_rows: 1000,
    max_payload_bytes: 10000,
    max_pages: 3,
    max_depth: 64,
  })
  let failed = try {
    let _ = limited.scan_btree(root, _ => true)
    false
  } catch {
    LimitExceeded(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "index child cycle and mixed page types are rejected" {
  let original = fixture_btree()
  let db = open_database(original)
  let root = db.schema().filter(entry => entry.name == "mixed_index")[0].root_page
  let page = db.page(root)
  assert_eq(page.kind, IndexInterior)
  let bytes = original.to_array()
  let offset = (root - 1) * 512 + page.cell_offsets[0]
  bytes[offset] = (root >> 24).to_byte()
  bytes[offset + 1] = (root >> 16).to_byte()
  bytes[offset + 2] = (root >> 8).to_byte()
  bytes[offset + 3] = root.to_byte()
  let failed = try {
    let _ = open_database(Bytes::from_array(bytes)).read_index(root)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
  let failed = try {
    let _ = db.read_index(1)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "overflow pages cannot be shared with btree or another record" {
  let overflow = Bytes::make(512, 0)
  let db = open_database(test_database() + overflow)
  let cell = Bytes::make(40, 1) + b"\x00\x00\x00\x02" + Bytes::make(468, 0)
  let occupied : Map[Int, PageUse] = Map([])
  occupied[2] = Btree
  let failed = try {
    let _ = db.cell_payload_tracked(cell, 0, 548, true, occupied)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
  let occupied : Map[Int, PageUse] = Map([])
  assert_eq(db.cell_payload_tracked(cell, 0, 548, true, occupied).length(), 548)
  let failed = try {
    let _ = db.cell_payload_tracked(cell, 0, 548, true, occupied)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "visitor errors propagate and each scan starts with fresh ownership" {
  let db = open_database(fixture_btree())
  let root = db.schema().filter(entry => entry.name == "mixed_index")[0].root_page
  let failed = try {
    let _ = db.scan_btree(root, _ => raise Invalid("调用者停止处理"))
    false
  } catch {
    Invalid(message) => message == "调用者停止处理"
    _ => false
  }
  assert_true(failed)
  assert_eq(db.scan_btree(root, _ => false).completion, VisitorStopped)
  assert_eq(db.scan_btree(root, _ => true).completion, Complete)
}
