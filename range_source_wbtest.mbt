///|
priv struct VirtualRangeSource {
  size : Int64
  requests : Array[(Int64, Int)]
  fail_pages : Bool
  short_pages : Bool
}

///|
priv struct AdapterFaultSource {
  fail : Bool
}

///|
impl PageSource for AdapterFaultSource with fn byte_length(_self) {
  4
}

///|
impl PageSource for AdapterFaultSource with fn read_range(self, _offset, _count) {
  if self.fail {
    raise Invalid("旧宿主实际抛出错误")
  }
  b""
}

///|
test "public legacy adapter distinguishes bounds short reads and host failures" {
  let source = PageSourceAdapter::new(BytesSource::new(b"abcd"))
  assert_eq(source.read_range64(4L, 0), b"")
  for (offset, count) in [(4L, 1), (0L, -1), (-1L, 0), (2147483648L, 0)] {
    assert_true(
      try {
        ignore(source.read_range64(offset, count))
        false
      } catch {
        RangeOutOfBounds(_) => true
        _ => false
      },
    )
  }
  assert_true(
    try {
      ignore(
        PageSourceAdapter::new(AdapterFaultSource::{ fail: false, }).read_range64(
          0L, 4,
        ),
      )
      false
    } catch {
      ShortRead(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(
        PageSourceAdapter::new(AdapterFaultSource::{ fail: true, }).read_range64(
          0L, 4,
        ),
      )
      false
    } catch {
      HostFailure(message) => message == "旧宿主实际抛出错误"
      _ => false
    },
  )
}

///|
impl RangeSource for VirtualRangeSource with fn byte_length64(self) {
  self.size
}

///|
impl RangeSource for VirtualRangeSource with fn read_range64(
  self,
  offset,
  count,
) {
  self.requests.push((offset, count))
  if count == 100 {
    return test_header(512)
  }
  if self.fail_pages {
    raise HostFailure("磁盘读取失败")
  }
  if self.short_pages {
    return b""
  }
  if offset == 0L {
    return test_database()
  }
  b"\x0d\x00\x00\x00\x00\x02\x00\x00" + Bytes::make(504, 0)
}

///|
test "64 bit page addressing crosses 2 GiB without loading the file" {
  let source : VirtualRangeSource = {
    size: 2147484160L,
    requests: [],
    fail_pages: false,
    short_pages: false,
  }
  let db = open_range_source(source)
  assert_eq(db.page_count(), 4194305)
  assert_eq(db.page(4194305).number, 4194305)
  assert_eq(source.requests, [(0L, 100), (2147483648L, 512)])
  assert_eq(db.inspect_database().status, Incomplete)
  // 全局预算预检无需枚举四百万页；独立页读取与扫描仍可使用。
  assert_eq(source.requests.length(), 2)
  assert_eq(db.inspect_btree(4194305).status, Complete)
  assert_eq(db.source.byte_length(), -1)
  assert_eq(db.source64().byte_length64(), 2147484160L)
}

///|
test "new host failures and short reads stay incomplete in every report" {
  for short_pages in [false, true] {
    let source : VirtualRangeSource = {
      size: 512L,
      requests: [],
      fail_pages: !short_pages,
      short_pages,
    }
    let db = open_range_source(source)
    assert_eq(db.inspect_page(1).status, Incomplete)
    let tree = db.inspect_btree_details(1)
    assert_eq(tree.inspection.status, Incomplete)
    assert_eq(tree.location.unwrap().phase, ReadPage)
    let report = db.inspect_database_details()
    assert_eq(report.inspection.status, Incomplete)
    assert_eq(report.issues[0].location.unwrap().phase, ReadPage)
    assert_true(
      match tree.inspection.error {
        Some(Unsupported(message)) => message.has_prefix("source/")
        _ => false
      },
    )
  }
}

///|
test "range checks avoid signed overflow and zero length reads at EOF succeed" {
  let source = BytesSource::new(test_database())
  assert_eq(source.read_range64(512L, 0), b"")
  for
    (offset, count) in [
      (-1L, 1),
      (513L, 0),
      (512L, 1),
      (9223372036854775807L, 1),
      (0L, -1),
    ] {
    assert_true(
      try {
        ignore(source.read_range64(offset, count))
        false
      } catch {
        RangeOutOfBounds(_) => true
        _ => false
      },
    )
  }
  let wide : VirtualRangeSource = {
    size: 2147483647L * 65536L + 65536L,
    requests: [],
    fail_pages: false,
    short_pages: false,
  }
  assert_true(
    try {
      ignore(open_range_source(wide))
      false
    } catch {
      LimitExceeded(_) => true
      _ => false
    },
  )
}

///|
test "bounded FIFO cache evicts and preserves cross block and short tail reads" {
  let bytes = fixture_core()
  let cache = CachedSource::new(
    BytesSource::new(bytes),
    block_size=512,
    max_pages=2,
  )
  assert_eq(cache.read_range64(500L, 40), bytes[500:540].to_owned())
  assert_eq(cache.statistics().misses, 2L)
  ignore(cache.read_range64(0L, 1))
  assert_eq(cache.statistics().hits, 1L)
  ignore(cache.read_range64(1024L, 1))
  ignore(cache.read_range64(0L, 1))
  assert_eq(cache.statistics().misses, 4L)
  assert_eq(cache.statistics().resident_pages, 2)
  let tail = CachedSource::new(
    BytesSource::new(b"abcdef"),
    block_size=4,
    max_pages=1,
  )
  assert_eq(tail.read_range64(2L, 4), b"cdef")
  assert_eq(tail.statistics().bytes_read, 6L)
  assert_eq(tail.read_range64(6L, 0), b"")
}

///|
test "legacy adapter and range databases produce identical records and independent report budgets" {
  let old = open_database(fixture_core())
  let source = PageSourceAdapter::new(BytesSource::new(fixture_core()))
  let wide = open_range_source(source, max_report_pages=1)
  assert_eq(wide.header(), old.header())
  assert_eq(
    wide.table_rows("samples")[0].values,
    old.table_rows("samples")[0].values,
  )
  assert_eq(wide.inspect_database().status, Incomplete)
  assert_true(wide.inspect_database().pages.is_empty())
  let cached = open_range_source(CachedSource::new(source, max_pages=1))
  assert_eq(cached.inspect_database().status, old.inspect_database().status)
}

///|
test "largest supported page number retains its full 64 bit byte offset" {
  let source : VirtualRangeSource = {
    size: 2147483647L * 512L,
    requests: [],
    fail_pages: false,
    short_pages: false,
  }
  let db = open_range_source(source)
  assert_eq(db.page_count(), 2147483647)
  assert_eq(db.page(2147483647).number, 2147483647)
  assert_eq(source.requests[1], (2147483646L * 512L, 512))
}
