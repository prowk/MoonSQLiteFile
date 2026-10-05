///|
fn test_ptrmap_database() -> Bytes {
  let bytes = (test_database() + Bytes::make(1024, 0)).to_array()
  // schema 记录定义根页 3 的空表，页 2 保存一条根页反向指针。
  bytes[55] = 3
  bytes[104] = 1
  bytes[105] = 1
  bytes[106] = 240
  bytes[108] = 1
  bytes[109] = 240
  let cell = b"\x0e\x01\x06\x17\x0f\x0f\x01\x00tablett\x03"
  for i = 0; i < cell.length(); i = i + 1 {
    bytes[496 + i] = cell[i]
  }
  bytes[512] = 1
  bytes[1024] = 13
  bytes[1029] = 2
  Bytes::from_array(bytes)
}

///|
test "ptrmap root entries and auto vacuum coverage" {
  let db = open_database(test_ptrmap_database())
  assert_eq(db.ptrmap_entries(), [
    { page_number: 3, map_page: 2, kind: RootPage, parent_page: 0, },
  ])
  let report = db.inspect_database()
  assert_eq(report.status, InspectionStatus::Complete)
  assert_true(report.ownership_complete && report.ptrmap_checked)
  assert_eq(report.pages.length(), 3)
  assert_eq(report.pages[1].kind, PointerMap)
  assert_eq(report.roots_inspected, 2)
  assert_eq(report.records_decoded, 1)
  assert_eq(open_database(test_database()).ptrmap_entries(), [])
  let bytes = test_database().to_array()
  bytes[55] = 1
  let report = open_database(Bytes::from_array(bytes)).inspect_database()
  assert_eq(report.status, InspectionStatus::Complete)
  assert_true(report.ptrmap_checked)
}

///|
test "ptrmap mismatch preserves complete ownership and diagnostic evidence" {
  let bytes = test_ptrmap_database().to_array()
  bytes[512] = 2
  let db = open_database(Bytes::from_array(bytes))
  assert_eq(db.ptrmap_entries()[0].kind, FreePage)
  let report = db.inspect_database()
  assert_eq(report.status, InspectionStatus::Failed)
  assert_true(report.ownership_complete && report.ptrmap_checked)
  assert_true(
    report.issues.any(issue => {
      match issue {
        PtrmapMismatch(entry, owner) =>
          entry.kind == FreePage &&
          owner.kind == BtreeRoot &&
          owner.page_number == 3
        _ => false
      }
    }),
  )
}

///|
test "invalid ptrmap tags parents and largest root fail validation" {
  for (offset, value) in [(512, 0), (512, 6), (516, 1), (55, 4), (55, 1)] {
    let bytes = test_ptrmap_database().to_array()
    bytes[offset] = value.to_byte()
    let report = open_database(Bytes::from_array(bytes)).inspect_database()
    assert_eq(report.status, InspectionStatus::Failed)
    assert_true(
      report.issues.any(issue => {
        match issue {
          ScanError(_, Invalid(_)) => true
          _ => false
        }
      }),
    )
  }
}

///|
test "ptrmap lock byte displacement and resource limits" {
  // 保留空间让 Ptrmap 恰好落在 lock-byte 页，验证后移而无需生成大文件。
  let lock = 1073741824 / 1024 + 1
  assert_eq(ptrmap_page_number(lock + 1, 770, 1024), lock + 1)
  assert_eq(ptrmap_page_number(lock + 2, 770, 1024), lock + 1)
  assert_eq(ptrmap_page_number(lock + 155, 770, 1024), lock + 155)
  let db = open_database(test_ptrmap_database(), limits={
    max_rows: 100,
    max_payload_bytes: 1024,
    max_pages: 2,
    max_depth: 8,
  })
  try {
    ignore(db.ptrmap_entries())
    fail("应拒绝超出页预算的 Ptrmap 枚举")
  } catch {
    LimitExceeded(_) => ()
    _ => fail("应返回 LimitExceeded")
  }
  let db = open_database(test_ptrmap_database(), limits={
    max_rows: 1,
    max_payload_bytes: 1024,
    max_pages: 10,
    max_depth: 8,
  })
  let report = db.inspect_database(max_total_payload_bytes=0UL)
  assert_eq(report.status, InspectionStatus::Incomplete)
  assert_true(!report.ownership_complete && !report.ptrmap_checked)
}
