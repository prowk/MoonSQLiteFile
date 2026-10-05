///|
test "empty schema and name lookup errors" {
  let db = open_database(test_database())
  assert_eq(db.schema().length(), 0)
  assert_eq(db.table_rows("sqlite_master").length(), 0)
  let failed = try {
    let _ = db.table_rows("missing")
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}
