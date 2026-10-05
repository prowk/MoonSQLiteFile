///|
test "全库游标与同步报告一致且不主动读取" {
  let db = open_database(fixture_core())
  let cursor = db.inspection_cursor()
  let mut requests = 0
  let mut progress = 0
  while true {
    match cursor.next() {
      NeedInspectionPage(number) => {
        requests = requests + 1
        match cursor.next() {
          NeedInspectionPage(same) => assert_eq(same, number)
          _ => fail("未供页时请求必须稳定")
        }
        cursor.provide_page(number, db.read_page(number))
      }
      InspectionProgress(_) => progress = progress + 1
      InspectionFinished(details) => {
        let expected = db.inspect_database_details()
        assert_eq(details.inspection.pages, expected.inspection.pages)
        assert_eq(
          details.inspection.records_decoded,
          expected.inspection.records_decoded,
        )
        assert_eq(
          details.inspection.payload_bytes,
          expected.inspection.payload_bytes,
        )
        assert_eq(details.inspection.status, expected.inspection.status)
        assert_eq(details.issues.length(), expected.issues.length())
        assert_true(requests > 0 && progress > 0)
        break
      }
    }
  }
}

///|
test "全库取消与宿主失败保留部分页和定位" {
  let db = open_database(fixture_core())
  let cursor = db.inspection_cursor()
  while cursor.progress().records_read < 10 {
    match cursor.next() {
      NeedInspectionPage(number) =>
        cursor.provide_page(number, db.read_page(number))
      InspectionProgress(_) => ()
      InspectionFinished(_) => fail("应在完成前暂停")
    }
  }
  let partial = cursor.stop()
  assert_eq(partial.inspection.status, Incomplete)
  assert_false(partial.inspection.ownership_complete)
  assert_true(partial.inspection.pages.length() > 0)
  assert_true(partial.issues[0].location is Some(_))
  let failed = db.inspection_cursor()
  match failed.next() {
    NeedInspectionPage(1) =>
      failed.reject_page(Unsupported("source/short_read"))
    _ => fail("先请求 schema")
  }
  ignore(failed.next())
  match failed.next() {
    InspectionFinished(details) => {
      assert_eq(details.inspection.status, Incomplete)
      assert_false(details.inspection.ownership_complete)
    }
    _ => fail("schema 失败须结束根页发现")
  }
}
