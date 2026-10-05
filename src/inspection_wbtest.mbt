///|
test "inspection distinguishes full traversal from a record prefix" {
  let db = open_database(fixture_btree())
  let root = db.schema().filter(entry => entry.name == "mixed_index")[0].root_page
  let report = db.inspect_btree(root, limit=600)
  assert_eq(report.root_page, root)
  assert_eq(report.status, InspectionStatus::Complete)
  assert_eq(report.records_decoded, 600)
  assert_true(report.error is None)
  assert_eq(report.summary.unwrap().completion, ScanCompletion::Complete)
  let report = db.inspect_btree(root, limit=7)
  assert_eq(report.status, InspectionStatus::Incomplete)
  assert_eq(report.records_decoded, 7)
  assert_true(report.error is None)
  assert_eq(report.summary.unwrap().completion, RecordLimit)
  assert_eq(
    db.inspect_btree(root, limit=0).status,
    InspectionStatus::Incomplete,
  )
  assert_eq(
    open_database(test_database()).inspect_btree(1, limit=0).status,
    InspectionStatus::Complete,
  )
}

///|
test "inspection retains decoded progress before later page corruption" {
  let original = fixture_btree()
  let db = open_database(original)
  let root = db.schema().filter(entry => entry.name == "indexed_rows")[0].root_page
  let records = db.read_btree(root)
  let last_page = records[records.length() - 1].page_number
  let expected = records
    .filter(record => record.page_number != last_page)
    .length()
  assert_true(expected > 0)
  let bytes = original.to_array()
  // 破坏最后一个叶页，确保前面的记录仍能成功读取。
  bytes[(last_page - 1) * db.header().page_size] = 0
  let report = open_database(Bytes::from_array(bytes)).inspect_btree(root)
  assert_eq(report.status, InspectionStatus::Failed)
  assert_eq(report.records_decoded, expected)
  assert_true(report.summary is None)
  assert_true(
    match report.error {
      Some(Invalid(_)) => true
      _ => false
    },
  )
}

///|
test "inspection reports exhausted budgets without claiming corruption" {
  let db = open_database(fixture_btree())
  let root = db.schema().filter(entry => entry.name == "long_key_index")[0].root_page
  let report = db.inspect_btree(root, max_total_payload_bytes=1500UL)
  assert_eq(report.status, InspectionStatus::Incomplete)
  assert_true(report.records_decoded > 0)
  assert_true(report.records_decoded < 24)
  assert_true(report.summary is None)
  assert_true(
    match report.error {
      Some(LimitExceeded(_)) => true
      _ => false
    },
  )
  let report = db.inspect_btree(root, limit=-1)
  assert_eq(report.status, InspectionStatus::Incomplete)
  assert_eq(report.records_decoded, 0)
  assert_true(
    match report.error {
      Some(LimitExceeded(_)) => true
      _ => false
    },
  )
}

///|
test "inspection preserves invalid roots and unsupported host errors" {
  let db = open_database(test_database())
  let report = db.inspect_btree(0)
  assert_eq(report.root_page, 0)
  assert_eq(report.status, InspectionStatus::Failed)
  assert_eq(report.records_decoded, 0)
  assert_true(
    match report.error {
      Some(Invalid(_)) => true
      _ => false
    },
  )
  let source = InspectionUnsupportedSource::{ data: test_database(), }
  let report = open_source(source).inspect_btree(1)
  assert_eq(report.status, InspectionStatus::Incomplete)
  assert_eq(report.records_decoded, 0)
  assert_true(
    match report.error {
      Some(Unsupported(message)) => message == "宿主不支持该范围读取"
      _ => false
    },
  )
}

///|
priv struct InspectionUnsupportedSource {
  data : Bytes
}

///|
impl PageSource for InspectionUnsupportedSource with fn byte_length(self) {
  self.data.length()
}

///|
impl PageSource for InspectionUnsupportedSource with fn read_range(
  self,
  offset,
  count,
) {
  if count != 100 {
    raise Unsupported("宿主不支持该范围读取")
  }
  self.data[offset:offset + count].to_owned()
}
