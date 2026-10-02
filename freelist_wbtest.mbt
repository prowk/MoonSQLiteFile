///|
test "empty freelist and corrupt count" {
  assert_eq(open_database(test_database()).freelist().length(), 0)
  let bytes = test_database().to_array()
  bytes[39] = 1
  let failed = try {
    let _ = open_database(Bytes::from_array(bytes)).freelist()
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}
