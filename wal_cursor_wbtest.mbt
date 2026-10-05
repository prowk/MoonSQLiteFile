///|
fn drive_wal_cursor(
  data : Bytes,
  max_frames : Int,
) -> (WalCursor, RangeWalInspection) raise {
  let cursor = WalCursor::new(data.length().to_int64(), max_frames~)
  while true {
    match cursor.next() {
      NeedWalRange(offset, count) => {
        match cursor.next() {
          NeedWalRange(repeated, length) => {
            assert_eq(repeated, offset)
            assert_eq(length, count)
          }
          _ => abort("WAL 未供帧却改变请求")
        }
        cursor.provide(
          offset,
          data[offset.to_int():offset.to_int() + count].to_owned(),
        )
      }
      WalReady(report) => return (cursor, report)
    }
  } nobreak {
    abort("WAL 游标未结束")
  }
}

///|
test "WAL pull cursor preserves commit tail and frame-budget boundaries" {
  for order in [LittleEndianChecksum, BigEndianChecksum] {
    let first = wal_test_append(wal_test_header(order), 1U, 1U, test_database())
    let pending = wal_test_append(first, 1U, 0U, test_database())
    for
      (bytes, reason, offset, committed) in [
        (b"", WalEndOfFile, 0L, 0),
        (first, WalEndOfFile, 568L, 1),
        (pending, WalEndOfFile, 1104L, 1),
        (first + b"tail", WalTruncatedFrame, 568L, 1),
      ] {
      let (_, report) = drive_wal_cursor(bytes, 3)
      assert_eq(report.stop_reason, reason)
      assert_eq(report.stop_offset, offset)
      assert_eq(report.committed_frames, committed)
      assert_eq(
        report.stop_offset + report.trailing_bytes,
        bytes.length().to_int64(),
      )
    }
    let (cursor, limited) = drive_wal_cursor(pending, 1)
    assert_eq(limited.stop_reason, WalFrameLimit)
    assert_eq(limited.stop_offset, 568L)
    assert_true(
      try {
        ignore(
          RangeWalSource::from_cursor(
            BytesSource::new(test_database()),
            BytesSource::new(pending),
            cursor,
            tail_policy=UseValidPrefix,
          ),
        )
        false
      } catch {
        LimitExceeded(_) => true
        _ => false
      },
    )
    let (cursor, report) = drive_wal_cursor(first, 2)
    // 对外报告是快照；修改数组不能改写游标内部已经验证的帧。
    report.frames.clear()
    report.commits.clear()
    let snapshot = RangeWalSource::from_cursor(
      BytesSource::new(b""),
      BytesSource::new(first),
      cursor,
    )
    assert_eq(snapshot.page_range(1), WalPage(56L))
    assert_eq(open_range_wal_source(snapshot).schema().length(), 0)
    cursor.close()
    assert_eq(snapshot.inspection().frames.length(), 1)
  }
}

///|
test "WAL pull cursor rejects stale supply and cannot expose cancelled snapshots" {
  let cursor = WalCursor::new(568L)
  assert_true(
    try {
      cursor.provide(0L, b"")
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  ignore(cursor.next())
  assert_true(
    try {
      cursor.provide(1L, wal_test_header(BigEndianChecksum))
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  cursor.provide(0L, wal_test_header(BigEndianChecksum))
  assert_true(
    try {
      cursor.provide(0L, wal_test_header(BigEndianChecksum))
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  ignore(cursor.next())
  cursor.close()
  assert_eq(cursor.frames_read(), 0)
  assert_true(
    try {
      ignore(cursor.next())
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(
        RangeWalSource::from_cursor(
          BytesSource::new(test_database()),
          BytesSource::new(b""),
          cursor,
        ),
      )
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
}
