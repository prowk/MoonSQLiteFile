///|
test "record empty null constants and empty fields" {
  assert_eq(decode_record(b"\x01", 1), [])
  assert_eq(decode_record(b"\x06\x00\x08\x09\x0c\x0d", 1), [
    Null, Integer(0L), Integer(1L), Blob(b""), Text(""),
  ])
}

///|
test "record signed integer widths and boundaries" {
  assert_eq(decode_record(b"\x07\x01\x02\x03\x04\x05\x06\xff\xff\xfe\xff\xff\xfd\xff\xff\xff\xfc\xff\xff\xff\xff\xff\xfb\xff\xff\xff\xff\xff\xff\xff\xfa", 1), [
    Integer(-1L), Integer(-2L), Integer(-3L), Integer(-4L), Integer(-5L), Integer(-6L),
  ])
  assert_eq(decode_record(b"\x03\x01\x06\x7f\x80\x00\x00\x00\x00\x00\x00\x00", 1), [
    Integer(127L), Integer(-9223372036854775808L),
  ])
  assert_eq(decode_record(b"\x02\x06\x7f\xff\xff\xff\xff\xff\xff\xff", 1), [Integer(9223372036854775807L)])
}

///|
test "record big endian double" {
  assert_eq(decode_record(b"\x02\x07\x3f\xf8\x00\x00\x00\x00\x00\x00", 1), [Real(1.5)])
  assert_eq(decode_record(b"\x02\x07\xc0\x04\x00\x00\x00\x00\x00\x00", 1), [Real(-2.5)])
}

///|
test "record blob and utf8" {
  assert_eq(decode_record(b"\x03\x12\x13\x00\xff\x80\xe4\xb8\xad", 1), [Blob(b"\x00\xff\x80"), Text("中")])
  assert_eq(decode_record(b"\x02\x13\xef\xbb\xbf", 1), [Text("\u{FEFF}")])
}

///|
test "record utf16 both endiannesses and surrogate pairs" {
  assert_eq(decode_record(b"\x02\x19\x2d\x4e\x3d\xd8\x00\xde", 2), [Text("中😀")])
  assert_eq(decode_record(b"\x02\x19\x4e\x2d\xd8\x3d\xde\x00", 3), [Text("中😀")])
  assert_eq(decode_record(b"\x02\x11\xff\xfe", 2), [Text("\u{FEFF}")])
}

///|
test "record multi byte header size and serial type" {
  let many_nulls = b"\x81\x00" + Bytes::make(126, b'\x00')
  assert_eq(decode_record(many_nulls, 1), Array::make(126, Null))
  let text = Bytes::make(64, b'a')
  assert_eq(decode_record(b"\x03\x81\x0d" + text, 1), [Text("a".repeat(64))])
}

///|
fn assert_invalid_record(payload : Bytes, encoding : Int) -> Unit raise {
  let invalid = try {
    let _ = decode_record(payload, encoding)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(invalid)
}

///|
test "record rejects malformed headers and size overflow" {
  for data in [b"", b"\x00", b"\x03\x00", b"\x80", b"\x02\x80\x01", b"\x01\x00", b"\xff\xff\xff\xff\xff\xff\xff\xff\xff"] {
    assert_invalid_record(data, 1)
  }
  assert_invalid_record(b"\x0a\xff\xff\xff\xff\xff\xff\xff\xff\xff", 1)
}

///|
test "record rejects reserved types and mismatched bodies" {
  for data in [b"\x02\x0a", b"\x02\x0b", b"\x02\x01", b"\x02\x01\x01\x01", b"\x02\x12\x00\x01"] {
    assert_invalid_record(data, 1)
  }
}

///|
test "record rejects malformed unicode and unsupported encoding" {
  assert_invalid_record(b"\x02\x11\xc0\xaf", 1)
  assert_invalid_record(b"\x02\x15\xf4\x90\x80\x80", 1)
  assert_invalid_record(b"\x02\x0f\x00", 2)
  assert_invalid_record(b"\x02\x11\x00\xd8", 2)
  assert_invalid_record(b"\x02\x11\xdc\x00", 3)
  assert_invalid_record(b"\x01", 0)
  assert_invalid_record(b"\x01", 4)
}
