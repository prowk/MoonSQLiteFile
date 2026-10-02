///|
test "freelist cannot claim schema page" {
  let first = test_database().to_array()
  first[35] = 2
  first[39] = 2
  let trunk : Array[Byte] = Array::make(512, 0)
  trunk[7] = 1
  trunk[11] = 1
  let db = open_database(Bytes::from_array(first) + Bytes::from_array(trunk))
  let failed = try {
    let _ = db.freelist()
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "freeblock self cycle is rejected" {
  let first = test_database().to_array()
  first[101] = 1
  first[102] = 244
  first[105] = 1
  first[106] = 244
  first[500] = 1
  first[501] = 244
  first[503] = 4
  let failed = try {
    let _ = open_database(Bytes::from_array(first)).page(1)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "interior child loop and wrong separator are rejected" {
  let original = fixture_core()
  let db = open_database(original)
  let page = db.page(3)
  let pointer = (3 - 1) * 512 + page.cell_offsets[0]
  let broken = original.to_array()
  broken[pointer] = 0
  broken[pointer + 1] = 0
  broken[pointer + 2] = 0
  broken[pointer + 3] = 3
  let failed = try {
    let _ = open_database(Bytes::from_array(broken)).read_table(3)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
  let broken = original.to_array()
  let (key, count) = decode_varint(original, pointer + 4)
  assert_true(key > 1UL)
  // 同长度且仍递增的较小 separator 必须违反子树的上界。
  broken[pointer + 4 + count - 1] = (broken[pointer + 4 + count - 1].to_int() -
  1).to_byte()
  let failed = try {
    let _ = open_database(Bytes::from_array(broken)).read_table(3)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "cell varint cannot read reserved bytes" {
  let failed = try {
    let _ = page_varint(b"\x80\x01", 0, 1)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "NULL schema rootpage is valid for views" {
  let record = b"\x06\x15\x0f\x0f\x00\x00viewvv"
  let bytes = test_database().to_array()
  bytes[104] = 1
  bytes[105] = 1
  bytes[106] = 242
  bytes[108] = 1
  bytes[109] = 242
  bytes[498] = 12
  bytes[499] = 1
  for i = 0; i < record.length(); i = i + 1 {
    bytes[500 + i] = record[i]
  }
  let entries = open_database(Bytes::from_array(bytes)).schema()
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].object_type, "view")
  assert_eq(entries[0].root_page, 0)
}
