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

///|
fn uneven_leaf_depth_fixture(first_leaf_nonempty : Bool) -> Bytes {
  let root = test_database().to_array()
  let root_header = b"\x05\x00\x00\x00\x01\x01\xfb\x00\x00\x00\x00\x03\x01\xfb"
  for i = 0; i < root_header.length(); i = i + 1 {
    root[100 + i] = root_header[i]
  }
  let separator = b"\x00\x00\x00\x02\x01"
  for i = 0; i < separator.length(); i = i + 1 {
    root[507 + i] = separator[i]
  }
  let leaf = b"\x0d\x00\x00\x00\x00\x02\x00\x00" + Bytes::make(504, 0)
  let left = leaf.to_array()
  if first_leaf_nonempty {
    // 左叶页可为空或包含一条记录；右叶页经由额外内部页，始终比左侧深一层。
    left[4] = 1
    left[5] = 1
    left[6] = 252
    left[8] = 1
    left[9] = 252
    let cell = b"\x02\x01\x02\x08"
    for i = 0; i < cell.length(); i = i + 1 {
      left[508 + i] = cell[i]
    }
  }
  let branch = b"\x05\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x04" +
    Bytes::make(500, 0)
  Bytes::from_array(root) + Bytes::from_array(left) + branch + leaf
}

///|
test "empty child pages cannot hide missing records at any depth" {
  for first_leaf_nonempty in [false, true] {
    let db = open_database(uneven_leaf_depth_fixture(first_leaf_nonempty))
    let report = db.inspect_btree(1)
    assert_eq(report.status, InspectionStatus::Failed)
    assert_eq(report.records_decoded, if first_leaf_nonempty { 1 } else { 0 })
    assert_true(
      match report.error {
        Some(Invalid(message)) =>
          message == "B-tree 非根页面或非页 1 内部根页不能为空"
        _ => false
      },
    )
  }
}

///|
test "empty table and index roots remain valid and page one permits a virtual root" {
  for kind in [13, 10] {
    assert_eq(
      open_database(space_fixture(kind.to_byte(), 512, [], 0, [])).inspect_btree(
        2,
      ).status,
      Complete,
    )
  }
  for kind in [5, 2] {
    assert_eq(
      open_database(space_fixture(kind.to_byte(), 512, [], 0, [])).inspect_btree(
        2,
      ).status,
      Failed,
    )
  }
  // 页 1 因为数据库头占用空间，可以保留零 cell 的内部虚拟根。
  let root = test_database().to_array()
  root[100] = 5
  root[111] = 2
  let leaf = space_fixture(13, 508, [(508, b"\x02\x01\x02\x08")], 0, [])
  let db = open_database(Bytes::from_array(root) + leaf[512:].to_owned())
  assert_eq(db.inspect_btree(1).status, Complete)
  assert_eq(db.inspect_btree(1).records_decoded, 1)
  let empty = space_fixture(13, 512, [], 0, [])
  assert_eq(
    open_database(Bytes::from_array(root) + empty[512:].to_owned()).inspect_btree(
      1,
    ).status,
    Failed,
  )
}

///|
test "nonempty leaf pages at different depths are still rejected" {
  let original = uneven_leaf_depth_fixture(true)
  let branch = space_fixture(5, 507, [(507, b"\x00\x00\x00\x04\x02")], 0, []).to_array()
  branch[512 + 11] = 5
  let leaf = space_fixture(13, 508, [(508, b"\x02\x02\x02\x08")], 0, [])
  let tail = space_fixture(13, 508, [(508, b"\x02\x03\x02\x08")], 0, [])
  let data = original[0:1024].to_owned() +
    Bytes::from_array(branch)[512:].to_owned() +
    leaf[512:].to_owned() +
    tail[512:].to_owned()
  let report = open_database(data).inspect_btree_details(1)
  assert_eq(report.inspection.status, Failed)
  assert_eq(report.inspection.records_decoded, 1)
  assert_eq(report.location.unwrap().page_number, Some(4))
  assert_true(
    match report.inspection.error {
      Some(Invalid(message)) => message == "B-tree 叶页深度不一致"
      _ => false
    },
  )
}
