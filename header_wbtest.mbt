///|
fn test_header(page_size : Int) -> Bytes {
  let data : FixedArray[Byte] = FixedArray::make(100, 0)
  let magic = b"SQLite format 3\x00"
  for i = 0; i < 16; i = i + 1 {
    data[i] = magic[i]
  }
  let encoded = if page_size == 65536 { 1 } else { page_size }
  data[16] = (encoded >> 8).to_byte()
  data[17] = encoded.to_byte()
  data[18] = 1
  data[19] = 1
  data[21] = 64
  data[22] = 32
  data[23] = 32
  data[47] = 4
  data[59] = 1
  Bytes::from_array(data[:])
}

///|
test "SQLite header page sizes and corruption" {
  assert_eq(parse_header(test_header(4096)).page_size, 4096)
  assert_eq(parse_header(test_header(65536)).page_size, 65536)
  let failed = try {
    let _ = parse_header(test_header(1000))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  let data = test_header(512).to_fixedarray()
  data[20] = 33
  let failed = try {
    let _ = parse_header(Bytes::from_array(data[:]))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}
