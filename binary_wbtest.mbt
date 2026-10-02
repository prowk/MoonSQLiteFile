///|
test "varint boundaries and signed rowid bits" {
  assert_eq(decode_varint(b"\x00", 0), (0UL, 1))
  assert_eq(decode_varint(b"\x7f", 0), (127UL, 1))
  assert_eq(decode_varint(b"\x81\x00", 0), (128UL, 2))
  assert_eq(
    decode_varint(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff", 0),
    (18446744073709551615UL, 9),
  )
  assert_eq(read_u16(b"\x12\x34", 0), 4660)
  assert_eq(read_u32(b"\xff\xff\xff\xff", 0), 4294967295U)
}

///|
test "truncated and negative reads raise" {
  let failed = try {
    let _ = decode_varint(b"\x80", 0)
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  let failed = try {
    let _ = read_u16(b"\x00", -1)
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}
