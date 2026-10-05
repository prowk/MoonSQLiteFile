///|
test "range WAL matches byte snapshots through shrink and regrowth" {
  let base = test_database() + Bytes::make(1024, 1)
  for order in [LittleEndianChecksum, BigEndianChecksum] {
    let first = wal_test_append(
      wal_test_header(order),
      3U,
      3U,
      Bytes::make(512, 3),
    )
    let shrunk = wal_test_append(first, 1U, 1U, test_database())
    let pending = wal_test_append(shrunk, 2U, 0U, Bytes::make(512, 7))
    let grown = wal_test_append(pending, 3U, 3U, Bytes::make(512, 8))
    for wal in [b"", first, shrunk, pending, grown] {
      let wide = RangeWalSource::new(
        BytesSource::new(base),
        BytesSource::new(wal),
      )
      let old = WalSource::new(BytesSource::new(base), wal)
      assert_eq(wide.page_count(), old.page_count())
      assert_eq(
        wide.read_range64(0L, old.byte_length()),
        old.read_range(0, old.byte_length()),
      )
      assert_eq(
        wide.inspection().stop_offset,
        old.inspection().stop_offset.to_int64(),
      )
    }
    let invalid = wal_test_append(shrunk, 1U, 3U, test_database())
    assert_true(
      try {
        ignore(
          RangeWalSource::new(BytesSource::new(base), BytesSource::new(invalid)),
        )
        false
      } catch {
        Invalid(_) => true
        _ => false
      },
    )
  }
}

///|
test "range WAL tail policy and independent frame and overlay budgets are strict" {
  let base = test_database() + Bytes::make(512, 5)
  let one = wal_test_append(
    wal_test_header(BigEndianChecksum),
    1U,
    0U,
    test_database(),
  )
  let wal = wal_test_append(one, 2U, 2U, Bytes::make(512, 9))
  let source = RangeWalSource::new(
    BytesSource::new(base),
    BytesSource::new(wal),
  )
  assert_eq(source.read_range64(508L, 8), b"\x00\x00\x00\x00\x09\x09\x09\x09")
  assert_eq(source.read_range64(1024L, 0), b"")
  for frame_budget in [true, false] {
    assert_true(
      try {
        ignore(
          RangeWalSource::new(
            BytesSource::new(base),
            BytesSource::new(wal),
            max_frames=if frame_budget { 1 } else { 2 },
            max_overlay_pages=if frame_budget { 2 } else { 1 },
            tail_policy=UseValidPrefix,
          ),
        )
        false
      } catch {
        LimitExceeded(_) => true
        _ => false
      },
    )
  }
  let tail = wal + b"bad"
  assert_true(
    try {
      ignore(
        RangeWalSource::new(BytesSource::new(base), BytesSource::new(tail)),
      )
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  let prefix = RangeWalSource::new(
    BytesSource::new(base),
    BytesSource::new(tail),
    tail_policy=UseValidPrefix,
  )
  assert_eq(prefix.read_range64(0L, 1024), source.read_range64(0L, 1024))
}

///|
test "range WAL can overlay pages beyond 2 GiB with small inputs" {
  let base : VirtualRangeSource = {
    size: 2147484160L,
    requests: [],
    fail_pages: false,
    short_pages: false,
  }
  let leaf = b"\x0d\x00\x00\x00\x00\x02\x00\x00" + Bytes::make(504, 0)
  let wal = wal_test_append(
    wal_test_header(BigEndianChecksum),
    4194305U,
    4194305U,
    leaf,
  )
  let source = RangeWalSource::new(base, BytesSource::new(wal))
  assert_eq(source.byte_length64(), 2147484160L)
  let db = open_range_wal_source(source)
  assert_eq(db.page(4194305).kind, TableLeaf)
  assert_eq(db.read_page(4194305), leaf)
  assert_eq(base.requests, [(0L, 100), (0L, 100)])
}

///|
test "range WAL reports 64 bit trailing sizes without reading past a frame budget" {
  let wal = wal_test_append(
    wal_test_header(BigEndianChecksum),
    1U,
    1U,
    test_database(),
  )
  let source : WideWalFixture = {
    data: wal,
    size: 4294967296L,
    requests: [],
    fail: false,
  }
  let report = inspect_wal_source(source, max_frames=1)
  assert_eq(report.stop_reason, WalFrameLimit)
  assert_eq(report.stop_offset, 568L)
  assert_eq(report.trailing_bytes, 4294966728L)
  assert_eq(source.requests, [(0L, 32), (32L, 536)])
  let failed : WideWalFixture = {
    data: wal,
    size: wal.length().to_int64(),
    requests: [],
    fail: true,
  }
  assert_true(
    try {
      ignore(
        RangeWalSource::new(
          BytesSource::new(test_database()),
          failed,
          tail_policy=UseValidPrefix,
        ),
      )
      false
    } catch {
      Unsupported(message) => message.has_prefix("source/host_failure:")
      _ => false
    },
  )
}

///|
priv struct WideWalFixture {
  data : Bytes
  size : Int64
  requests : Array[(Int64, Int)]
  fail : Bool
}

///|
impl RangeSource for WideWalFixture with fn byte_length64(self) {
  self.size
}

///|
impl RangeSource for WideWalFixture with fn read_range64(self, offset, count) {
  self.requests.push((offset, count))
  if self.fail && offset != 0L {
    raise HostFailure("WAL 读取失败")
  }
  self.data[offset.to_int():offset.to_int() + count].to_owned()
}

///|
test "range WAL can bootstrap an empty main file from a committed page one" {
  let wal = wal_test_append(
    wal_test_header(BigEndianChecksum),
    1U,
    1U,
    test_database(),
  )
  let source = RangeWalSource::new(BytesSource::new(b""), BytesSource::new(wal))
  assert_eq(open_range_wal_source(source).schema().length(), 0)
}

///|
priv struct HighOffsetWalPage {
  offset : Int64
  data : Bytes
  requests : Array[(Int64, Int)]
}

///|
impl RangeSource for HighOffsetWalPage with fn byte_length64(self) {
  self.offset + self.data.length().to_int64()
}

///|
impl RangeSource for HighOffsetWalPage with fn read_range64(self, offset, count) {
  self.requests.push((offset, count))
  if offset < self.offset ||
    offset + count.to_int64() > RangeSource::byte_length64(self) {
    raise RangeOutOfBounds("高位 WAL 请求越界")
  }
  let start = (offset - self.offset).to_int()
  self.data[start:start + count].to_owned()
}

///|
test "WAL overlay reads full pages and in-page slices at high frame payload offsets" {
  // 白盒隔离覆盖索引读取；全帧 checksum 和真实索引生成由扩展大 WAL 验收验证。
  for offset in [2148270136L, 4294967320L] {
    let wal : HighOffsetWalPage = {
      offset,
      data: test_database(),
      requests: [],
    }
    let inspection : RangeWalInspection = {
      header: None,
      frames: [],
      commits: [],
      committed_frames: 0,
      database_pages: Some(1U),
      stop_reason: WalEndOfFile,
      stop_offset: RangeSource::byte_length64(wal),
      trailing_bytes: 0L,
    }
    let source : RangeWalSource = {
      base: BytesSource::new(b""),
      wal,
      page_size: 512,
      page_count: 1,
      base_pages: 0,
      overlay: Map([(1, offset)]),
      inspection,
    }
    let db = open_range_wal_source(source)
    assert_eq(db.schema().length(), 0)
    assert_eq(source.read_range64(508L, 4), b"\x00\x00\x00\x00")
    assert_eq(wal.requests[0], (offset, 100))
    assert_true(wal.requests.contains((offset, 512)))
    assert_eq(wal.requests[wal.requests.length() - 1], (offset + 508L, 4))
  }
}
