///|
test "page one header begins after 100 bytes" {
  let page = open_database(test_database()).page(1)
  assert_eq(page.kind, TableLeaf)
  assert_eq(page.cell_count, 0)
  assert_eq(page.content_start, 512)
  let bytes = test_database().to_array()
  bytes[103] = 255
  let failed = try {
    let _ = open_database(Bytes::from_array(bytes)).page(1)
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}
