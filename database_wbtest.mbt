///|
fn test_database() -> Bytes {
  test_header(512) + b"\x0d\x00\x00\x00\x00\x02\x00\x00" + Bytes::make(404, 0)
}

///|
test "pager checks alignment and page numbers" {
  let db = open_database(test_database())
  assert_eq(db.page_count(), 1)
  assert_eq(db.read_page(1).length(), 512)
  let failed = try { let _ = db.read_page(0); false } catch { _ => true }
  assert_true(failed)
  let failed = try { let _ = open_database(test_database() + b"\x00"); false } catch { _ => true }
  assert_true(failed)
}

///|
test "stale declared page counts and incomplete snapshots" {
  let data = test_database().to_array()
  data[31] = 2
  let failed = try { let _ = open_database(Bytes::from_array(data)); false } catch { _ => true }
  assert_true(failed)
  data[27] = 1
  assert_eq(open_database(Bytes::from_array(data)).page_count(), 1)
}
