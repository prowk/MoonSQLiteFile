///|
test "summary accounts for each claimed page once and groups table index overflow and schema" {
  let report = open_database(fixture_btree()).inspect_database()
  let summary = report.summarize()
  assert_eq(summary.claimed_pages, 198)
  assert_eq(summary.unclaimed_pages, 0)
  assert_eq(summary.objects.length(), 10)
  assert_eq(summary.objects[0].object_name, Some("sqlite_schema"))
  let mut classified = 0
  for kind in summary.page_kinds {
    classified = classified + kind.pages
  }
  assert_eq(classified, 198)
  let mut object_pages = 0
  for object in summary.objects {
    object_pages = object_pages + object.btree_pages + object.overflow_pages
    let owners = report.pages.filter(p => {
      p.root_page == Some(object.root_page) &&
      p.object_name == object.object_name
    })
    assert_eq(object.btree_pages + object.overflow_pages, owners.length())
    assert_true(object.btree_pages >= 1)
  }
  assert_eq(object_pages, 198)
  for i = 1; i < summary.objects.length(); i = i + 1 {
    assert_true(summary.objects[i - 1].root_page < summary.objects[i].root_page)
  }
}

///|
test "summary preserves freelist pointer map and unclaimed categories outside objects" {
  let report = open_database(fixture_core()).inspect_database()
  let summary = report.summarize()
  assert_eq(summary.page_kinds[4].kind, FreelistTrunk)
  assert_eq(summary.page_kinds[5].kind, FreelistLeaf)
  assert_eq(summary.page_kinds[4].pages + summary.page_kinds[5].pages, 7)
  let mut object_pages = 0
  for object in summary.objects {
    object_pages = object_pages + object.btree_pages + object.overflow_pages
  }
  assert_eq(object_pages, summary.claimed_pages - 7)
  let summary = open_database(test_ptrmap_database())
    .inspect_database()
    .summarize()
  assert_eq(summary.page_kinds[6], { kind: PointerMap, pages: 1, })
  assert_eq(summary.objects.length(), 2)
  let report = open_database(test_database() + Bytes::make(512, 0)).inspect_database()
  let summary = report.summarize()
  assert_eq(summary.claimed_pages, 1)
  assert_eq(summary.unclaimed_pages, 1)
  assert_eq(summary.objects.length(), 1)
}

///|
test "incomplete and rejected scans produce observed counts without claiming full coverage" {
  let db = open_database(fixture_btree(), limits={
    max_rows: 1,
    max_payload_bytes: 16777216,
    max_pages: 1000,
    max_depth: 64,
  })
  let report = db.inspect_database()
  assert_eq(report.status, Incomplete)
  assert_true(!report.ownership_complete)
  let summary = report.summarize()
  assert_eq(summary.claimed_pages + summary.unclaimed_pages, db.page_count())
  assert_eq(summary.objects.length(), 1)
  let db = open_database(fixture_btree(), limits={
    max_rows: 1000,
    max_payload_bytes: 16777216,
    max_pages: 1,
    max_depth: 64,
  })
  let report = db.inspect_database()
  let summary = report.summarize()
  assert_eq(summary.claimed_pages, 0)
  assert_eq(summary.unclaimed_pages, 0)
  assert_eq(summary.objects, [])
  assert_true(!report.ownership_complete)
}

///|
test "summarizing a report does not read its source or mutate report ordering" {
  let source = CountingSource::{ data: fixture_core(), requests: [], }
  let report = open_source(source).inspect_database()
  let reads = source.requests.length()
  let before = report.pages.copy()
  let first = report.summarize()
  assert_eq(first, report.summarize())
  assert_eq(report.pages, before)
  assert_eq(source.requests.length(), reads)
}
