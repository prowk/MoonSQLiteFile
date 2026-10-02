///|
test "SQLite payload distribution thresholds" {
  assert_eq(local_payload_size(477, 512, true), 477)
  assert_eq(local_payload_size(478, 512, true), 39)
  assert_eq(local_payload_size(548, 512, true), 40)
  assert_eq(local_payload_size(102, 512, false), 102)
  assert_eq(local_payload_size(103, 512, false), 39)
}

///|
test "overflow links enforce bounds cycles and resource limits" {
  let overflow : Array[Byte] = Array::make(512, 0)
  // 第二页回指自身，读取超出一页时必须报告环。
  overflow[3] = 2
  let db = open_database(test_database() + Bytes::from_array(overflow))
  let cell = Bytes::make(39, 1) + b"\x00\x00\x00\x02" + Bytes::make(469, 0)
  let failed = try { let _ = db.cell_payload(cell, 0, 1000, true); false } catch { _ => true }
  assert_true(failed)
  let db = open_database(test_database(), limits={ max_rows: 10, max_payload_bytes: 10, max_pages: 10, max_depth: 10 })
  let failed = try { let _ = db.cell_payload(b"", 0, 11, true); false } catch { _ => true }
  assert_true(failed)
}
