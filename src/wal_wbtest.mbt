///|
fn wal_test_u32(bytes : Array[Byte], offset : Int, value : UInt) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    bytes[offset + i] = (value >> ((3 - i) * 8)).to_byte()
  }
}

///|
fn wal_test_header(order : WalChecksumOrder, page_size? : Int = 512) -> Bytes {
  let bytes : Array[Byte] = Array::make(32, 0)
  wal_test_u32(
    bytes,
    0,
    if order == LittleEndianChecksum {
      0x377f0682U
    } else {
      0x377f0683U
    },
  )
  wal_test_u32(bytes, 4, 3007000U)
  wal_test_u32(bytes, 8, page_size.reinterpret_as_uint())
  wal_test_u32(bytes, 12, 17U)
  wal_test_u32(bytes, 16, 0x11223344U)
  wal_test_u32(bytes, 20, 0x55667788U)
  let (a, b) = wal_checksum(Bytes::from_array(bytes), 0, 24, order, (0U, 0U))
  wal_test_u32(bytes, 24, a)
  wal_test_u32(bytes, 28, b)
  Bytes::from_array(bytes)
}

///|
fn wal_test_append(
  wal : Bytes,
  page : UInt,
  commit : UInt,
  payload : Bytes,
) -> Bytes raise SqliteError {
  let header = parse_wal_header(wal)
  let bytes : Array[Byte] = Array::make(24, 0)
  wal_test_u32(bytes, 0, page)
  wal_test_u32(bytes, 4, commit)
  wal_test_u32(bytes, 8, header.salt1)
  wal_test_u32(bytes, 12, header.salt2)
  let previous = if wal.length() == 32 {
    (header.checksum1, header.checksum2)
  } else {
    let offset = wal.length() - header.page_size - 24
    (read_u32(wal, offset + 16), read_u32(wal, offset + 20))
  }
  let next = wal_checksum(
    Bytes::from_array(bytes),
    0,
    8,
    header.checksum_order,
    previous,
  )
  let next = wal_checksum(
    payload,
    0,
    payload.length(),
    header.checksum_order,
    next,
  )
  wal_test_u32(bytes, 16, next.0)
  wal_test_u32(bytes, 20, next.1)
  wal + Bytes::from_array(bytes) + payload
}

///|
test "WAL header checksums match independent endian vectors" {
  let little = b"\x37\x7f\x06\x82\x00\x2d\xe2\x18\x00\x00\x02\x00\x00\x00\x00\x11\x11\x22\x33\x44\x55\x66\x77\x88\x29\xfe\x25\x24\x7b\x4f\x63\x1e"
  let big = b"\x37\x7f\x06\x83\x00\x2d\xe2\x18\x00\x00\x02\x00\x00\x00\x00\x11\x11\x22\x33\x44\x55\x66\x77\x88\x27\x26\xfe\x2c\x23\x66\x4f\x7e"
  assert_eq(parse_wal_header(little).checksum_order, LittleEndianChecksum)
  assert_eq(parse_wal_header(big).checksum_order, BigEndianChecksum)
  assert_eq(wal_test_header(LittleEndianChecksum), little)
  assert_eq(wal_test_header(BigEndianChecksum), big)
  assert_eq(
    parse_wal_header(wal_test_header(BigEndianChecksum, page_size=65536)).page_size,
    65536,
  )
}

///|
test "WAL validates header format before frames" {
  for field in [0, 8, 16, 24, 28] {
    let bytes = wal_test_header(LittleEndianChecksum).to_array()
    bytes[field] = 255
    let rejected = try {
      ignore(parse_wal_header(Bytes::from_array(bytes)))
      false
    } catch {
      Invalid(_) | LimitExceeded(_) => true
      _ => false
    }
    assert_true(rejected)
  }
  let version = wal_test_header(BigEndianChecksum).to_array()
  version[4] = 1
  assert_true(
    try {
      ignore(parse_wal_header(Bytes::from_array(version)))
      false
    } catch {
      Unsupported(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(parse_wal_header(b""))
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
}

///|
test "WAL cumulative checksum stops before a broken middle frame and later commit" {
  for order in [LittleEndianChecksum, BigEndianChecksum] {
    let wal = wal_test_append(wal_test_header(order), 1U, 1U, test_database())
    let wal = wal_test_append(wal, 1U, 0U, test_database())
    let wal = wal_test_append(wal, 1U, 1U, test_database())
    let bytes = wal.to_array()
    bytes[32 + 536 + 30] = 255
    let report = inspect_wal(Bytes::from_array(bytes))
    assert_eq(report.frames.length(), 1)
    assert_eq(report.committed_frames, 1)
    assert_eq(report.database_pages, Some(1U))
    assert_eq(report.stop_reason, WalChecksumMismatch)
    assert_eq(report.stop_offset, 568)
    assert_eq(report.trailing_bytes, 1072)
  }
}

///|
test "WAL never exposes uncommitted updates to the same page" {
  let first = test_database().to_array()
  first[63] = 7
  let pending = test_database().to_array()
  pending[63] = 9
  let wal = wal_test_append(
    wal_test_header(LittleEndianChecksum),
    1U,
    1U,
    Bytes::from_array(first),
  )
  let wal = wal_test_append(wal, 1U, 0U, Bytes::from_array(pending))
  let report = inspect_wal(wal)
  assert_eq(report.frames.length(), 2)
  assert_eq(report.commits.length(), 1)
  assert_eq(report.committed_frames, 1)
  assert_eq(open_wal_database(test_database(), wal).header().user_version, 7U)
  let committed = wal_test_append(wal, 1U, 1U, Bytes::from_array(pending))
  assert_eq(
    open_wal_database(test_database(), committed).header().user_version,
    9U,
  )
}

///|
test "WAL strict and prefix tail policies retain only the last preceding commit" {
  let wal = wal_test_append(
    wal_test_header(BigEndianChecksum),
    1U,
    1U,
    test_database(),
  )
  let next = wal_test_append(wal, 1U, 1U, test_database())
  for
    (offset, reason) in [
      (wal.length() + 8, WalSaltMismatch),
      (wal.length() + 16, WalChecksumMismatch),
      (wal.length(), WalInvalidFrame),
    ] {
    let bytes = next.to_array()
    bytes[offset] = if reason == WalInvalidFrame { 0 } else { 255 }
    if reason == WalInvalidFrame {
      bytes[offset + 3] = 0
    }
    let damaged = Bytes::from_array(bytes)
    assert_eq(inspect_wal(damaged).stop_reason, reason)
    assert_true(
      try {
        ignore(open_wal_database(test_database(), damaged))
        false
      } catch {
        Invalid(_) => true
        _ => false
      },
    )
    assert_eq(
      open_wal_database(test_database(), damaged, tail_policy=UseValidPrefix).page_count(),
      1,
    )
  }
  for count in [1, 23, 24, 535] {
    let cut = next[0:wal.length() + count].to_owned()
    assert_eq(inspect_wal(cut).stop_reason, WalTruncatedFrame)
    assert_eq(
      open_wal_database(test_database(), cut, tail_policy=UseValidPrefix).page_count(),
      1,
    )
  }
}

///|
test "WAL frame budgets cannot substitute an earlier snapshot" {
  let wal = wal_test_append(
    wal_test_header(BigEndianChecksum),
    1U,
    1U,
    test_database(),
  )
  assert_eq(inspect_wal(wal, max_frames=1).stop_reason, WalEndOfFile)
  let more = wal_test_append(wal, 1U, 1U, test_database())
  assert_eq(inspect_wal(more, max_frames=1).stop_reason, WalFrameLimit)
  assert_true(
    try {
      ignore(
        open_wal_database(
          test_database(),
          more,
          max_frames=1,
          tail_policy=UseValidPrefix,
        ),
      )
      false
    } catch {
      LimitExceeded(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(inspect_wal(wal, max_frames=0))
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
}

///|
test "WAL logical size is authoritative even if page one declares a stale size" {
  let one = fixture_empty()
  let two = Bytes::make(512, 2)
  let wal = wal_test_append(wal_test_header(BigEndianChecksum), 2U, 2U, two)
  let db = open_wal_database(one, wal)
  assert_eq(db.header().declared_pages, 1U)
  assert_eq(db.page_count(), 2)
  assert_eq(db.read_page(2), two)
  assert_eq(db.read_page(1), one)
}

///|
test "WAL truncate and regrow require new versions instead of old WAL or main pages" {
  let base = test_database() + Bytes::make(1024, 1)
  let wal = wal_test_append(
    wal_test_header(BigEndianChecksum),
    3U,
    3U,
    Bytes::make(512, 3),
  )
  let wal = wal_test_append(wal, 1U, 1U, test_database())
  let bad = wal_test_append(wal, 1U, 3U, test_database())
  assert_true(
    try {
      ignore(open_wal_database(base, bad))
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  let wal = wal_test_append(wal, 2U, 0U, Bytes::make(512, 7))
  let wal = wal_test_append(wal, 3U, 3U, Bytes::make(512, 8))
  let db = open_wal_database(base, wal)
  assert_eq(db.read_page(2), Bytes::make(512, 7))
  assert_eq(db.read_page(3), Bytes::make(512, 8))
}

///|
test "WAL source reads ranges across base and overlay pages without writing" {
  let base = CountingSource::{
    data: test_database() + Bytes::make(512, 5),
    requests: [],
  }
  let wal = wal_test_append(
    wal_test_header(BigEndianChecksum),
    2U,
    2U,
    Bytes::make(512, 9),
  )
  let source = WalSource::new(base, wal)
  assert_eq(source.byte_length(), 1024)
  assert_eq(source.read_range(508, 8), b"\x00\x00\x00\x00\x09\x09\x09\x09")
  assert_eq(source.read_range(1024, 0), b"")
  assert_true(
    try {
      ignore(source.read_range(1024, 1))
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  assert_eq(base.data[512], 5)
  assert_eq(source.inspection().database_pages, Some(2U))
  assert_eq(open_wal_source(source).page_count(), 2)
}

///|
test "WAL without commits retains main snapshot and complete page one can bootstrap an empty base" {
  let wal = wal_test_append(
    wal_test_header(BigEndianChecksum),
    1U,
    0U,
    Bytes::make(512, 255),
  )
  assert_eq(
    open_wal_database(test_database(), wal).read_page(1),
    test_database(),
  )
  let committed = wal_test_append(
    wal_test_header(BigEndianChecksum),
    1U,
    1U,
    test_database(),
  )
  assert_eq(open_wal_database(b"", committed).schema().length(), 0)
  assert_true(
    try {
      ignore(open_wal_database(b"", wal))
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
}

///|
test "WAL source detects page size mismatch host short reads and address overflow" {
  assert_true(
    try {
      ignore(
        WalSource::new(
          BytesSource::new(test_database()),
          wal_test_header(BigEndianChecksum, page_size=1024),
        ),
      )
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(
        WalSource::new(
          ShortSource::{ size: 512, returns: b"", },
          wal_test_header(BigEndianChecksum),
        ),
      )
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  let wal = wal_test_append(
    wal_test_header(BigEndianChecksum),
    1U,
    0x7fffffffU,
    test_database(),
  )
  assert_true(
    try {
      ignore(open_wal_database(test_database(), wal))
      false
    } catch {
      LimitExceeded(_) => true
      _ => false
    },
  )
  let wal = wal_test_append(
    wal_test_header(BigEndianChecksum),
    1U,
    1U,
    test_database(),
  )
  let db = open_wal_database(test_database(), wal)
  assert_eq(db.schema().length(), 0)
}

///|
test "zero byte WAL represents no pending journal without inventing a header" {
  let report = inspect_wal(b"")
  assert_eq(report.header, None)
  assert_eq(report.stop_reason, WalEndOfFile)
  assert_eq(open_wal_database(test_database(), b"").schema().length(), 0)
  assert_true(
    try {
      ignore(open_wal_database(b"", b""))
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
}
