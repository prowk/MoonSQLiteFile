///|
fn statistics_total(stats : PageStatistics) -> Int {
  stats.database_header_bytes +
  stats.btree_header_bytes +
  stats.pointer_bytes +
  stats.unallocated_bytes +
  stats.cell_bytes +
  stats.freeblock_bytes +
  stats.fragmented_bytes +
  stats.reserved_bytes
}

///|
test "page statistics partition all page space and separate payload from cell bytes" {
  let db = open_database(
    space_fixture(
      13,
      495,
      [(495, b"\x02\x01\x02\x08"), (508, b"\x02\x02\x02\x00")],
      1,
      [(500, 0, 8)],
    ),
  )
  let report = db.inspect_page(2)
  assert_eq(report.status, Complete)
  assert_true(report.diagnostic is None)
  assert_eq(report.page.unwrap().cell_count, 2)
  let stats = report.statistics.unwrap()
  assert_eq(statistics_total(stats), 512)
  assert_eq(stats.database_header_bytes, 0)
  assert_eq(stats.btree_header_bytes, 8)
  assert_eq(stats.pointer_bytes, 4)
  assert_eq(stats.unallocated_bytes, 483)
  assert_eq(stats.cell_bytes, 8)
  assert_eq(stats.freeblock_bytes, 8)
  assert_eq(stats.fragmented_bytes, 1)
  assert_eq(stats.payload_bytes, 4UL)
  assert_eq(stats.local_payload_bytes, 4UL)
  assert_eq(stats.max_payload_bytes, 2)
  assert_eq(stats.overflow_cells, 0)
}

///|
test "page one header empty leaves and reserved bytes have separate statistics" {
  let report = open_database(test_database()).inspect_page(1)
  let stats = report.statistics.unwrap()
  assert_eq(stats.database_header_bytes, 100)
  assert_eq(stats.btree_header_bytes, 8)
  assert_eq(stats.unallocated_bytes, 404)
  assert_eq(stats.cell_bytes, 0)
  assert_eq(statistics_total(stats), 512)
  let data = space_fixture(13, 476, [(476, b"\x02\x01\x02\x08")], 0, []).to_array()
  data[20] = 32
  data[105] = 1
  data[106] = 224
  let stats = open_database(Bytes::from_array(data)).inspect_page(2).statistics.unwrap()
  assert_eq(stats.reserved_bytes, 32)
  assert_eq(statistics_total(stats), 512)
}

///|
test "all four page kinds count cell headers padding and local payload" {
  for
    (kind, cell, payload, header) in [
      (13, b"\x01\x01\x01\x00", 1, 8),
      (10, b"\x02\x02\x00\x00", 2, 8),
      (5, b"\x00\x00\x00\x01\x01", 0, 12),
      (2, b"\x00\x00\x00\x01\x02\x02\x00", 2, 12),
    ] {
    let start = 512 - cell.length()
    let stats = open_database(
      space_fixture(kind.to_byte(), start, [(start, cell)], 0, []),
    ).inspect_page(2).statistics.unwrap()
    assert_eq(stats.btree_header_bytes, header)
    assert_eq(stats.cell_bytes, cell.length())
    assert_eq(stats.payload_bytes, payload.to_uint64())
    assert_eq(stats.local_payload_bytes, payload.to_uint64())
    assert_eq(statistics_total(stats), 512)
  }
}

///|
priv struct PageReportSource {
  data : Bytes
  reads : Array[(Int, Int)]
  fail_page : Bool
}

///|
impl PageSource for PageReportSource with fn byte_length(self) {
  self.data.length()
}

///|
impl PageSource for PageReportSource with fn read_range(self, offset, count) {
  self.reads.push((offset, count))
  if self.fail_page && count != 100 {
    raise Invalid("宿主页面读取失败")
  }
  self.data[offset:offset + count].to_owned()
}

///|
test "declared overflow statistics inspect only the requested page without following links" {
  let cell = b"\x83\x5e\x01" + Bytes::make(39, 0) + b"\x00\x00\x00\x09"
  let data = space_fixture(13, 466, [(466, cell)], 0, [])
  let source = PageReportSource::{ data, reads: [], fail_page: false, }
  let db = open_source(source)
  let report = db.inspect_page(2)
  assert_eq(report.status, Complete)
  let stats = report.statistics.unwrap()
  assert_eq(stats.payload_bytes, 478UL)
  assert_eq(stats.local_payload_bytes, 39UL)
  assert_eq(stats.max_payload_bytes, 478)
  assert_eq(stats.overflow_cells, 1)
  assert_eq(stats.cell_bytes, 46)
  assert_eq(source.reads, [(0, 100), (512, 512)])
  // 页布局完整不代表 overflow 链正确；普通扫描仍拒绝越界链接。
  assert_eq(db.inspect_btree(2).status, Failed)
}

///|
test "page diagnostic identifies pointer field cell index and preserves the original error" {
  let data = space_fixture(13, 508, [(508, b"\x02\x01\x02\x00")], 0, []).to_array()
  data[512 + 8] = 0
  let db = open_database(Bytes::from_array(data))
  let report = db.inspect_page(2)
  assert_eq(report.status, Failed)
  assert_true(report.page is None)
  assert_true(report.statistics is None)
  let diagnostic = report.diagnostic.unwrap()
  assert_eq(diagnostic.code, CellPointer)
  assert_eq(diagnostic.page_number, 2)
  assert_eq(diagnostic.byte_offset, Some(8))
  assert_eq(diagnostic.cell_index, Some(0))
  match diagnostic.error {
    Invalid(message) => assert_eq(message, "cell 指针越界或重复")
    _ => fail("页格式错误必须保留 Invalid")
  }
  assert_space_invalid(Bytes::from_array(data))
}

///|
test "page diagnostics distinguish overlap gap fragments and malformed cells" {
  for
    (data, code, offset, index) in [
      (
        space_fixture(
          10,
          500,
          [
            (500, b"\x02\x02\x00"),
            (503, b"\x02\x02\x00"),
            (508, b"\x02\x02\x00\x00"),
          ],
          0,
          [],
        ),
        SpaceOverlap,
        503,
        Some(1),
      ),
      (
        space_fixture(
          13,
          496,
          [(496, b"\x02\x01\x02\x08"), (508, b"\x02\x02\x02\x00")],
          0,
          [],
        ),
        FragmentCount,
        7,
        None,
      ),
      (
        space_fixture(
          13,
          502,
          [(502, b"\x02\x01\x02\x08"), (508, b"\x02\x02\x02\x00")],
          0,
          [],
        ),
        FragmentCount,
        7,
        None,
      ),
      (
        space_fixture(13, 508, [(508, b"\x80\x80\x80\x80")], 0, []),
        CellFormat,
        508,
        Some(0),
      ),
      (
        space_fixture(
          13,
          488,
          [(488, b"\x02\x01\x02\x08"), (508, b"\x02\x02\x02\x00")],
          0,
          [(492, 496, 4), (496, 0, 12)],
        ),
        Freeblock,
        492,
        None,
      ),
    ] {
    let report = open_database(data).inspect_page(2)
    assert_eq(report.status, Failed)
    let diagnostic = report.diagnostic.unwrap()
    assert_eq(diagnostic.code, code)
    assert_eq(diagnostic.byte_offset, Some(offset))
    assert_eq(diagnostic.cell_index, index)
  }
}

///|
test "invalid host reads and out of range pages remain incomplete with no fabricated offset" {
  let source = PageReportSource::{
    data: test_database(),
    reads: [],
    fail_page: true,
  }
  let db = open_source(source)
  for number in [0, 1, 2] {
    let report = db.inspect_page(number)
    assert_eq(report.status, Incomplete)
    let diagnostic = report.diagnostic.unwrap()
    assert_eq(diagnostic.code, PageRead)
    assert_eq(diagnostic.page_number, number)
    assert_eq(diagnostic.byte_offset, None)
    assert_eq(diagnostic.cell_index, None)
    assert_true(report.statistics is None)
  }
  let short = open_source(ShortSource::{ size: 512, returns: test_header(512), })
  let report = short.inspect_page(1)
  assert_eq(report.status, Incomplete)
  assert_eq(report.diagnostic.unwrap().code, PageRead)
  assert_eq(report.diagnostic.unwrap().byte_offset, None)
}

///|
test "empty 65536 byte page uses zero content sentinel in page statistics" {
  let data = test_header(65536) +
    b"\x0d\x00\x00\x00\x00\x00\x00\x00" +
    Bytes::make(65428, 0)
  let report = open_database(data).inspect_page(1)
  assert_eq(report.status, Complete)
  assert_eq(report.page.unwrap().content_start, 65536)
  assert_eq(statistics_total(report.statistics.unwrap()), 65536)
  assert_eq(report.statistics.unwrap().unallocated_bytes, 65428)
}

///|
test "page header type and wide right child diagnostics retain field locations" {
  for
    (data, code, offset) in [
      (space_fixture(0, 512, [], 0, []), PageTypeTag, 0),
      (space_fixture(13, 1, [], 0, []), PageHeader, 5),
    ] {
    let diagnostic = open_database(data).inspect_page(2).diagnostic.unwrap()
    assert_eq(diagnostic.code, code)
    assert_eq(diagnostic.byte_offset, Some(offset))
  }
  let bytes = space_fixture(5, 512, [], 0, []).to_array()
  bytes[512 + 8] = 255
  let report = open_database(Bytes::from_array(bytes)).inspect_page(2)
  assert_eq(report.status, Incomplete)
  assert_eq(report.diagnostic.unwrap().code, ChildPointer)
  assert_eq(report.diagnostic.unwrap().byte_offset, Some(8))
}
