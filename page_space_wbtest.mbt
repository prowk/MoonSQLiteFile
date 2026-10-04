///|
fn space_fixture(
  kind : Byte,
  content_start : Int,
  cells : Array[(Int, Bytes)],
  fragments : Int,
  blocks : Array[(Int, Int, Int)],
) -> Bytes {
  let bytes : Array[Byte] = Array::make(512, 0)
  let interior = kind == 2 || kind == 5
  bytes[0] = kind
  bytes[3] = (cells.length() >> 8).to_byte()
  bytes[4] = cells.length().to_byte()
  bytes[5] = (content_start >> 8).to_byte()
  bytes[6] = content_start.to_byte()
  bytes[7] = fragments.to_byte()
  if interior {
    bytes[11] = 1
  }
  let pointers = if interior { 12 } else { 8 }
  for i = 0; i < cells.length(); i = i + 1 {
    let (offset, cell) = cells[i]
    bytes[pointers + i * 2] = (offset >> 8).to_byte()
    bytes[pointers + i * 2 + 1] = offset.to_byte()
    for j = 0; j < cell.length(); j = j + 1 {
      bytes[offset + j] = cell[j]
    }
  }
  if !blocks.is_empty() {
    bytes[1] = (blocks[0].0 >> 8).to_byte()
    bytes[2] = blocks[0].0.to_byte()
  }
  for (offset, next, size) in blocks {
    bytes[offset] = (next >> 8).to_byte()
    bytes[offset + 1] = next.to_byte()
    bytes[offset + 2] = (size >> 8).to_byte()
    bytes[offset + 3] = size.to_byte()
  }
  test_database() + Bytes::from_array(bytes)
}

///|
fn assert_space_invalid(data : Bytes) -> Unit raise {
  try {
    ignore(open_database(data).page(2))
    fail("损坏的页面空间必须被拒绝")
  } catch {
    Invalid(_) => ()
    _ => fail("页面空间损坏必须返回 Invalid")
  }
}

///|
test "cell space covers all four btree formats and tiny cell padding" {
  for
    (kind, cell) in [
      (13, b"\x01\x01\x01\x00"),
      (10, b"\x02\x02\x00\x00"),
      (5, b"\x00\x00\x00\x01\x01"),
      (2, b"\x00\x00\x00\x01\x02\x02\x00"),
    ] {
    let start = 512 - cell.length()
    let data = space_fixture(kind.to_byte(), start, [(start, cell)], 0, [])
    let db = open_database(data)
    assert_eq(db.page(2).cell_count, 1)
    if kind == 13 {
      assert_eq(db.read_btree(2)[0].values, [])
    }
  }
}

///|
test "physical cell order and one to three byte fragments remain valid" {
  for gap in [0, 1, 2, 3] {
    let start = 504 - gap
    // cell 指针按键排序，实际存储位置可逆序；区间检查不能依赖逻辑顺序。
    let data = space_fixture(
      13,
      start,
      [(508, b"\x02\x01\x02\x08"), (start, b"\x02\x02\x02\x00")],
      gap,
      [],
    )
    let db = open_database(data)
    assert_eq(db.page(2).fragmented_bytes, gap)
    assert_eq(db.read_btree(2).length(), 2)
  }
}

///|
test "freeblocks and cell regions jointly cover the content area" {
  let data = space_fixture(
    13,
    496,
    [(496, b"\x02\x01\x02\x08"), (508, b"\x02\x02\x02\x00")],
    0,
    [(500, 0, 8)],
  )
  let db = open_database(data)
  assert_eq(db.page(2).first_freeblock, 500)
  assert_eq(db.read_btree(2).length(), 2)
}

///|
test "freeblocks must be separated by at least one minimum sized cell" {
  for gap in [0, 1, 2, 3] {
    assert_space_invalid(
      space_fixture(
        13,
        488,
        [(488, b"\x02\x01\x02\x08"), (508, b"\x02\x02\x02\x00")],
        gap,
        [(492, 496 + gap, 4), (496 + gap, 0, 12 - gap)],
      ),
    )
  }
  let data = space_fixture(
    13,
    488,
    [
      (488, b"\x02\x01\x02\x08"),
      (496, b"\x02\x02\x02\x00"),
      (508, b"\x02\x03\x02\x00"),
    ],
    0,
    [(492, 500, 4), (500, 0, 8)],
  )
  assert_eq(open_database(data).read_btree(2).length(), 3)
}

///|
test "cell contents and minimum padding cannot overlap another cell" {
  for
    (kind, cells) in [
      (
        13,
        [
          (496, b"\x0a\x01" + Bytes::make(10, 0)),
          (500, b"\x0a\x02" + Bytes::make(10, 0)),
        ],
      ),
      (
        10,
        [
          (500, b"\x02\x02\x00"),
          (503, b"\x02\x02\x00"),
          (508, b"\x02\x02\x00\x00"),
        ],
      ),
    ] {
    assert_space_invalid(
      space_fixture(kind.to_byte(), cells[0].0, cells, 0, []),
    )
  }
}

///|
test "freeblocks cannot intersect cell contents beyond the cell pointer" {
  assert_space_invalid(
    space_fixture(
      13,
      496,
      [(496, b"\x06\x01\x02\x14abcd"), (508, b"\x02\x02\x02\x00")],
      0,
      [(500, 0, 8)],
    ),
  )
}

///|
test "untracked gaps and inaccurate fragment counts are rejected" {
  for (start, declared) in [(496, 0), (502, 0), (502, 1), (502, 3)] {
    assert_space_invalid(
      space_fixture(
        13,
        start,
        [(start, b"\x02\x01\x02\x08"), (508, b"\x02\x02\x02\x00")],
        declared,
        [],
      ),
    )
  }
  assert_space_invalid(space_fixture(13, 508, [], 0, [(508, 0, 4)]))
  assert_space_invalid(space_fixture(13, 512, [], 1, []))
}

///|
test "cell extent includes nine byte rowids and overflow pointers" {
  let negative_rowid = b"\xff\xff\xff\xff\xff\xff\xff\xff\xff"
  let cell = b"\x83\x5e" +
    negative_rowid +
    Bytes::make(39, 0) +
    b"\x00\x00\x00\x01"
  let start = 512 - cell.length()
  assert_eq(
    open_database(space_fixture(13, start, [(start, cell)], 0, [])).page(2).cell_count,
    1,
  )
  for kind in [10, 2] {
    let prefix = if kind == 2 { b"\x00\x00\x00\x01" } else { b"" }
    let cell = prefix + b"\x67" + Bytes::make(39, 0) + b"\x00\x00\x00\x01"
    let start = 512 - cell.length()
    assert_eq(
      open_database(
        space_fixture(kind.to_byte(), start, [(start, cell)], 0, []),
      ).page(2).cell_count,
      1,
    )
    // 将 freeblock 放在 overflow 指针内部，cell 起点仍在空闲块之前。
    assert_space_invalid(
      space_fixture(kind.to_byte(), start, [(start, cell)], 0, [(508, 0, 4)]),
    )
  }
}

///|
test "cell sizes stop at usable space and include minimum padding" {
  assert_space_invalid(space_fixture(10, 509, [(509, b"\x02\x02\x00")], 0, []))
  assert_space_invalid(space_fixture(5, 509, [(509, b"\x00\x00\x00")], 0, []))
  let bytes = space_fixture(13, 476, [(476, b"\x02\x01\x02\x08")], 0, []).to_array()
  bytes[20] = 32
  bytes[105] = 1
  bytes[106] = 224
  assert_eq(open_database(Bytes::from_array(bytes)).page(2).content_start, 476)
  bytes[512 + 477] = 128
  assert_space_invalid(Bytes::from_array(bytes))
}

///|
test "SQLite fragmentation may include four byte gaps and tails" {
  for tail in [false, true] {
    let start = if tail { 500 } else { 496 }
    let cells = if tail {
      [(500, b"\x02\x01\x02\x08")]
    } else {
      [(496, b"\x02\x01\x02\x08"), (508, b"\x02\x02\x02\x00")]
    }
    let report = open_database(space_fixture(13, start, cells, 8, [])).inspect_page(
      2,
    )
    assert_eq(report.status, Complete)
    assert_eq(report.statistics.unwrap().fragmented_bytes, 8)
  }
}
