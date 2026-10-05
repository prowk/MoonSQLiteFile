///|
test "empty table scans and invalid roots" {
  let db = open_database(test_database())
  assert_eq(db.read_table(1).length(), 0)
  assert_eq(db.read_table(1, limit=0).length(), 0)
  let failed = try {
    let _ = db.read_table(2)
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}
