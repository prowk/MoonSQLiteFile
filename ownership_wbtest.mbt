///|
test "global ownership covers schema table index overflow and freelist" {
  for data in [test_database(), fixture_core(), fixture_btree()] {
    let db = open_database(data)
    let report = db.inspect_database()
    assert_eq(report.status, InspectionStatus::Complete)
    assert_true(report.ownership_complete)
    assert_true(report.ptrmap_checked)
    assert_eq(report.pages.length(), db.page_count())
    assert_eq(report.unclaimed_pages, [])
    assert_eq(report.issues.length(), 0)
    assert_eq(report.pages[0].kind, BtreeRoot)
    assert_eq(report.pages[0].root_page, Some(1))
    for i = 0; i < report.pages.length(); i = i + 1 {
      assert_eq(report.pages[i].page_number, i + 1)
    }
  }
  let report = open_database(fixture_btree()).inspect_database()
  assert_eq(report.roots_inspected, 10)
  assert_eq(report.records_decoded, 1478)
  assert_true(report.pages.any(page => page.kind == OverflowFirst))
  assert_true(report.pages.any(page => page.kind == BtreeChild))
  let report = open_database(fixture_core()).inspect_database()
  assert_eq(
    report.pages
    .filter(page => page.kind == FreelistTrunk || page.kind == FreelistLeaf)
    .length(),
    7,
  )
}

///|
test "global ownership detects aliased roots with both object names" {
  let original = fixture_btree()
  let db = open_database(original)
  let target = db.schema().filter(entry => entry.name == "indexed_rows")[0].root_page
  let record = db
    .read_btree(1)
    .filter(record => record.values[1] == Text("plain"))[0]
  let page = db.read_page(record.page_number)
  let (_, payload_size_bytes) = decode_varint(page, record.cell_offset)
  let (_, rowid_bytes) = decode_varint(
    page,
    record.cell_offset + payload_size_bytes,
  )
  let payload_start = record.cell_offset + payload_size_bytes + rowid_bytes
  let (header_size, size_bytes) = decode_varint(page, payload_start)
  let mut serial_at = payload_start + size_bytes
  let mut root_at = payload_start + header_size.to_int()
  for _i = 0; _i < 3; _i = _i + 1 {
    let (serial, width) = decode_varint(page, serial_at)
    serial_at = serial_at + width
    root_at = root_at + record_serial_length(serial)
  }
  let (root_serial, _) = decode_varint(page, serial_at)
  let root_width = record_serial_length(root_serial)
  assert_true(root_width > 0)
  let bytes = original.to_array()
  let absolute = (record.page_number - 1) * db.header().page_size + root_at
  for i = 0; i < root_width; i = i + 1 {
    bytes[absolute + i] = (target >> ((root_width - i - 1) * 8)).to_byte()
  }
  let report = open_database(Bytes::from_array(bytes)).inspect_database()
  assert_eq(report.status, InspectionStatus::Failed)
  assert_true(!report.ownership_complete)
  assert_true(
    report.issues.any(issue => {
      match issue {
        PageConflict(first, second) =>
          first.object_name == Some("indexed_rows") &&
          second.object_name == Some("plain") &&
          first.page_number == target
        _ => false
      }
    }),
  )
}

///|
test "unclaimed pages are conclusive only after complete root discovery" {
  let data = test_database() + Bytes::make(512, 0)
  let report = open_database(data).inspect_database()
  assert_eq(report.status, InspectionStatus::Failed)
  assert_true(report.ownership_complete)
  assert_eq(report.unclaimed_pages, [2])
  assert_true(
    report.issues.any(issue => {
      match issue {
        UnclaimedPage(2) => true
        _ => false
      }
    }),
  )
  let db = open_database(fixture_btree(), limits={
    max_rows: 1,
    max_payload_bytes: 16777216,
    max_pages: 1000,
    max_depth: 64,
  })
  let report = db.inspect_database()
  assert_eq(report.status, InspectionStatus::Incomplete)
  assert_true(!report.ownership_complete)
  assert_eq(report.records_decoded, 1)
  assert_true(!report.unclaimed_pages.is_empty())
  assert_true(
    !report.issues.any(issue => {
      match issue {
        UnclaimedPage(_) => true
        _ => false
      }
    }),
  )
}

///|
test "database budgets are shared across separate trees and bounded reports" {
  let original = fixture_btree()
  let db = open_database(original, limits={
    max_rows: 1000,
    max_payload_bytes: 16777216,
    max_pages: 1000,
    max_depth: 64,
  })
  let report = db.inspect_database()
  assert_eq(report.status, InspectionStatus::Incomplete)
  assert_eq(report.records_decoded, 1000)
  let report = open_database(original).inspect_database(
    max_total_payload_bytes=4000UL,
  )
  assert_eq(report.status, InspectionStatus::Incomplete)
  assert_true(report.payload_bytes <= 4000UL)
  let db = open_database(original, limits={
    max_rows: 100000,
    max_payload_bytes: 16777216,
    max_pages: 2,
    max_depth: 64,
  })
  let report = db.inspect_database()
  assert_eq(report.status, InspectionStatus::Incomplete)
  assert_eq(report.pages.length(), 0)
  assert_eq(report.roots_inspected, 0)
  let report = open_database(test_database() + Bytes::make(2048, 0)).inspect_database(
    max_issues=1,
  )
  assert_eq(report.status, InspectionStatus::Failed)
  assert_eq(report.issues.length(), 1)
  assert_true(report.diagnostics_truncated)
}

///|
test "freelist conflicts with pages already used by a live tree" {
  let original = fixture_core()
  let db = open_database(original)
  let free = db.freelist()[0]
  let bytes = original.to_array()
  let offset = (free - 1) * db.header().page_size + 8
  // 第一个 freelist leaf 改为已认领的 live table 根页。
  bytes[offset] = 0
  bytes[offset + 1] = 0
  bytes[offset + 2] = 0
  bytes[offset + 3] = 3
  let report = open_database(Bytes::from_array(bytes)).inspect_database()
  assert_eq(report.status, InspectionStatus::Failed)
  assert_true(
    report.issues.any(issue => {
      match issue {
        PageConflict(first, second) =>
          first.page_number == 3 && second.kind == FreelistLeaf
        _ => false
      }
    }),
  )
}
