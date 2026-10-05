///|
fn cursor_records(
  db : Database,
  root : Int,
  limit : Int,
  budget : UInt64,
) -> (Array[BTreeRecord], ScanSummary) raise {
  let cursor = db.scan_cursor(root, limit~, max_total_payload_bytes=budget)
  let records : Array[BTreeRecord] = []
  while true {
    match cursor.next() {
      NeedPage(number) => {
        // 不供页时请求稳定，不会重复计费或推进到后面的记录。
        match cursor.next() {
          NeedPage(repeated) => assert_eq(repeated, number)
          _ => abort("游标在未供页时自行前进")
        }
        cursor.provide_page(number, db.read_page(number))
      }
      RecordReady(record) => records.push(record)
      ScanFinished(summary) => return (records, summary)
    }
  } nobreak {
    abort("游标未终止")
  }
}

///|
test "pull cursor matches synchronous table index overflow and bounded scans" {
  for
    bytes in [
      fixture_core(),
      fixture_btree(),
      fixture_utf16le(),
      fixture_utf16be(),
      fixture_page65536(),
      test_database(),
    ] {
    let db = open_database(bytes)
    let roots = [1]
    for entry in db.schema() {
      if entry.root_page > 0 {
        roots.push(entry.root_page)
      }
    }
    for root in roots {
      for limit in [0, 1, 100000] {
        let expected : Array[BTreeRecord] = []
        let summary = db.scan_btree(
          root,
          record => {
            expected.push(record)
            true
          },
          limit~,
        )
        let (actual, pulled) = cursor_records(db, root, limit, 67108864UL)
        assert_eq(actual.length(), expected.length())
        for i = 0; i < actual.length(); i = i + 1 {
          assert_eq(actual[i].rowid, expected[i].rowid)
          assert_eq(actual[i].page_number, expected[i].page_number)
          assert_eq(actual[i].cell_offset, expected[i].cell_offset)
          assert_eq(actual[i].values, expected[i].values)
        }
        assert_eq(pulled.records_read, summary.records_read)
        assert_eq(pulled.pages_read, summary.pages_read)
        assert_eq(pulled.payload_bytes, summary.payload_bytes)
        assert_eq(pulled.completion, summary.completion)
      }
    }
  }
}

///|
test "pull cursor does no I/O and releases a paused scan on explicit stop" {
  let source : VirtualRangeSource = {
    size: 512L,
    requests: [],
    fail_pages: true,
    short_pages: false,
  }
  let cursor = open_range_source(source).scan_cursor(1)
  assert_eq(source.requests, [(0L, 100)])
  match cursor.next() {
    NeedPage(number) => assert_eq(number, 1)
    _ => abort("首次应请求根页")
  }
  assert_eq(source.requests, [(0L, 100)])
  assert_eq(cursor.progress(), {
    records_read: 0,
    pages_read: 0,
    payload_bytes: 0UL,
  })
  let summary = cursor.stop()
  assert_eq(summary.completion, VisitorStopped)
  match cursor.next() {
    ScanFinished(repeated) => assert_eq(repeated.completion, VisitorStopped)
    _ => abort("终止后不可再请求页面")
  }
  assert_true(
    cursor.stack.is_empty() && cursor.payload is None && cursor.supplied is None,
  )
}

///|
test "pull cursor rejects stale supply and retains diagnostics after budget errors" {
  let db = open_database(fixture_core())
  let cursor = db.scan_cursor(1, max_total_payload_bytes=0UL)
  assert_true(
    try {
      cursor.provide_page(1, db.read_page(1))
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  ignore(cursor.next())
  assert_true(
    try {
      cursor.provide_page(1, b"")
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  cursor.provide_page(1, db.read_page(1))
  assert_true(
    try {
      cursor.provide_page(1, db.read_page(1))
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      while true {
        match cursor.next() {
          NeedPage(number) => cursor.provide_page(number, db.read_page(number))
          _ => abort("零 payload 预算不应产生记录或完整结果")
        }
      } nobreak {
        false
      }
    } catch {
      LimitExceeded(_) => true
      _ => false
    },
  )
  assert_eq(cursor.location().phase, CellPayload)
  assert_eq(cursor.progress().records_read, 0)
  assert_true(
    try {
      ignore(cursor.next())
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
}
