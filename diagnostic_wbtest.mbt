///|
test "detailed tree reports locate child page layout failures without confusing them with root pages" {
  let data = uneven_leaf_depth_fixture(true).to_array()
  data[512 + 7] = 1
  let db = open_database(Bytes::from_array(data))
  let report = db.inspect_btree_details(1)
  assert_eq(report.inspection.root_page, 1)
  assert_eq(report.inspection.status, Failed)
  assert_eq(report.inspection.records_decoded, 0)
  let location = report.location.unwrap()
  assert_eq(location.phase, PageLayout)
  assert_eq(location.page_number, Some(2))
  assert_eq(location.byte_offset, Some(7))
  assert_eq(location.page_diagnostic.unwrap().code, FragmentCount)
}

///|
test "record decoding and tree depth diagnostics retain progress and actual cell context" {
  let db = open_database(
    space_fixture(13, 508, [(508, b"\x02\x01\x02\x0a")], 0, []),
  )
  let report = db.inspect_btree_details(2)
  assert_eq(report.inspection.status, Failed)
  let location = report.location.unwrap()
  assert_eq(location.phase, RecordDecode)
  assert_eq(location.page_number, Some(2))
  assert_eq(location.byte_offset, Some(508))
  assert_eq(location.cell_index, Some(0))
  assert_true(location.page_diagnostic is None)
  let report = open_database(uneven_leaf_depth_fixture(true)).inspect_btree_details(
    1,
  )
  assert_eq(report.inspection.records_decoded, 1)
  assert_eq(report.location.unwrap().phase, TreeTraversal)
  assert_eq(report.location.unwrap().page_number, Some(4))
  assert_eq(report.location.unwrap().byte_offset, None)
}

///|
test "overflow failures locate the link source or attempted read without stale cell positions" {
  let prefix = b"\x83\x5e\x01" + Bytes::make(39, 0)
  let db = open_database(
    space_fixture(13, 466, [(466, prefix + b"\x00\x00\x00\x00")], 0, []),
  )
  let report = db.inspect_btree_details(2)
  assert_eq(report.location.unwrap().phase, OverflowChain)
  assert_eq(report.location.unwrap().page_number, Some(2))
  assert_eq(report.location.unwrap().byte_offset, Some(508))
  let db = open_database(
    space_fixture(13, 466, [(466, prefix + b"\x00\x00\x00\x09")], 0, []),
  )
  let report = db.inspect_btree_details(2)
  assert_eq(report.location.unwrap().phase, ReadPage)
  assert_eq(report.location.unwrap().page_number, Some(9))
  assert_eq(report.location.unwrap().byte_offset, None)
  assert_eq(report.location.unwrap().cell_index, None)
}

///|
test "detailed tree budgets and successful prefixes have consistent legacy status" {
  let db = open_database(fixture_btree())
  let root = db.schema().filter(e => e.name == "indexed_rows")[0].root_page
  let report = db.inspect_btree_details(root, limit=1)
  assert_eq(report.inspection.status, Incomplete)
  assert_eq(report.inspection.records_decoded, 1)
  assert_true(report.location is None)
  let report = db.inspect_btree_details(root, max_total_payload_bytes=1UL)
  assert_eq(report.inspection.status, Incomplete)
  assert_eq(report.location.unwrap().phase, CellPayload)
  assert_true(report.location.unwrap().cell_index is Some(_))
  let report = db.inspect_btree_details(root, limit=-1)
  assert_eq(report.location.unwrap().phase, Configuration)
  assert_eq(report.location.unwrap().page_number, None)
  let report = db.inspect_btree_details(0)
  assert_eq(report.inspection.status, db.inspect_btree(0).status)
  assert_eq(report.location.unwrap().phase, ReadPage)
  assert_eq(report.location.unwrap().page_number, Some(0))
}

///|
test "global detailed reports preserve capped issue ordering and fresh per-issue locations" {
  let db = open_database(test_database() + Bytes::make(1536, 0))
  let report = db.inspect_database_details(max_issues=2)
  assert_eq(report.inspection.status, Failed)
  assert_true(report.inspection.diagnostics_truncated)
  assert_eq(report.issues.length(), 2)
  for i = 0; i < 2; i = i + 1 {
    match report.issues[i].issue {
      UnclaimedPage(number) => {
        assert_eq(number, i + 2)
        assert_eq(report.issues[i].location.unwrap().phase, PageOwnershipCheck)
        assert_eq(report.issues[i].location.unwrap().page_number, Some(number))
        assert_eq(report.issues[i].location.unwrap().byte_offset, None)
      }
      _ => fail("必须保留未知页诊断顺序")
    }
  }
  let report = open_database(fixture_btree()).inspect_database_details()
  assert_eq(report.inspection.status, Complete)
  assert_eq(report.issues.length(), 0)
}

///|
test "global schema record errors keep schema cell context" {
  let db = open_database(
    space_fixture(13, 508, [(508, b"\x02\x01\x02\x08")], 0, []),
  )
  // 第一页必须用于 sqlite_schema，因此将第二页 cell 布局移到第一页。
  let bytes = test_database().to_array()
  let page = db.read_page(2)
  for i = 0; i < 10; i = i + 1 {
    bytes[100 + i] = page[i]
  }
  for i = 508; i < 512; i = i + 1 {
    bytes[i] = page[i]
  }
  let report = open_database(Bytes::from_array(bytes)).inspect_database_details()
  assert_eq(report.inspection.status, Failed)
  assert_eq(report.inspection.records_decoded, 1)
  assert_eq(report.issues[0].location.unwrap().phase, SchemaDecode)
  assert_eq(report.issues[0].location.unwrap().page_number, Some(1))
  assert_eq(report.issues[0].location.unwrap().byte_offset, Some(508))
  assert_eq(report.issues[0].location.unwrap().cell_index, Some(0))
}

///|
test "freelist and source failure diagnostics identify their real fields" {
  let data = test_database() + Bytes::make(512, 0)
  let bytes = data.to_array()
  bytes[35] = 2
  bytes[39] = 1
  bytes[512 + 7] = 127
  let report = open_database(Bytes::from_array(bytes)).inspect_database_details()
  let location = report.issues[0].location.unwrap()
  assert_eq(location.phase, FreelistCheck)
  assert_eq(location.page_number, Some(2))
  assert_eq(location.byte_offset, Some(4))
  let source = FailingSource::{ data: test_database(), }
  let report = open_source(source).inspect_database_details()
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].location.unwrap().phase, ReadPage)
  assert_eq(report.issues[0].location.unwrap().page_number, Some(1))
  assert_eq(report.issues[0].location.unwrap().byte_offset, None)
}

///|
test "ptrmap tags parents and mismatches point to the map page rather than the object root" {
  for (offset, value, expected) in [(512, 0, 0), (516, 1, 1), (512, 2, 0)] {
    let data = test_ptrmap_database().to_array()
    data[offset] = value.to_byte()
    let report = open_database(Bytes::from_array(data)).inspect_database_details()
    assert_eq(report.inspection.status, Failed)
    let location = report.issues[0].location.unwrap()
    assert_eq(location.phase, PtrmapCheck)
    assert_eq(location.page_number, Some(2))
    assert_eq(location.byte_offset, Some(expected))
    assert_eq(location.cell_index, None)
  }
}
