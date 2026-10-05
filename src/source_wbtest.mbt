///|
priv struct CountingSource {
  data : Bytes
  requests : Array[(Int, Int)]
}

///|
impl PageSource for CountingSource with fn byte_length(self) {
  self.data.length()
}

///|
impl PageSource for CountingSource with fn read_range(self, offset, count) {
  self.requests.push((offset, count))
  require_range(self.data, offset, count)
  self.data[offset:offset + count].to_owned()
}

///|
priv struct ShortSource {
  size : Int
  returns : Bytes
}

///|
impl PageSource for ShortSource with fn byte_length(self) {
  self.size
}

///|
impl PageSource for ShortSource with fn read_range(self, _, _) {
  self.returns
}

///|
priv struct FailingSource {
  data : Bytes
}

///|
impl PageSource for FailingSource with fn byte_length(self) {
  self.data.length()
}

///|
impl PageSource for FailingSource with fn read_range(self, offset, count) {
  if count != 100 {
    raise Invalid("宿主读取失败")
  }
  self.data[offset:offset + count].to_owned()
}

///|
test "host source failures propagate through database access" {
  let db = open_source(FailingSource::{ data: test_database(), })
  let failed = try {
    let _ = db.page(1)
    false
  } catch {
    Invalid(message) => message == "宿主读取失败"
    _ => false
  }
  assert_true(failed)
}

///|
test "opening a custom source reads only the header" {
  let source = CountingSource::{ data: fixture_btree(), requests: [], }
  let db = open_source(source)
  assert_eq(source.requests, [(0, 100)])
  assert_eq(db.page_count(), source.data.length() / 512)
  let records = db.index_records("mixed_index", limit=2)
  assert_eq(records.length(), 2)
  assert_true(source.requests.length() > 1)
  for (offset, size) in source.requests[1:] {
    assert_eq(size, 512)
    assert_eq(offset % 512, 0)
  }
}

///|
test "source errors include partial ranges and invalid lengths" {
  let short = ShortSource::{ size: 512, returns: b"", }
  let failed = try {
    let _ = open_source(short)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
  let invalid = ShortSource::{ size: -1, returns: b"", }
  let failed = try {
    let _ = open_source(invalid)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
  let header_only = ShortSource::{ size: 512, returns: test_header(512), }
  let db = open_source(header_only)
  let failed = try {
    let _ = db.read_page(1)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "bytes source preserves existing database API" {
  let source = BytesSource::new(fixture_core())
  let from_source = open_source(source)
  let from_bytes = open_database(fixture_core())
  assert_eq(from_source.header(), from_bytes.header())
  assert_eq(
    from_source.table_rows("samples")[0].values,
    from_bytes.table_rows("samples")[0].values,
  )
  assert_eq(source.byte_length(), fixture_core().length())
  let failed = try {
    let _ = source.read_range(-1, 10)
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
  assert_true(failed)
}
