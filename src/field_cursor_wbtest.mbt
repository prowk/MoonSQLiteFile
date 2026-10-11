///|
fn field_chunk(
  db : Database,
  record : BTreeRecord,
  field : Int,
  offset : Int,
  length : Int,
) -> FieldChunk raise {
  let cursor = db.blob_chunk_cursor(
    record.page_number,
    record.cell_offset,
    field,
    offset~,
    length~,
  )
  defer cursor.stop()
  while true {
    match cursor.next() {
      NeedFieldPage(page) => {
        match cursor.next() {
          NeedFieldPage(repeated) => assert_eq(repeated, page)
          _ => abort("等待供页时状态改变")
        }
        cursor.provide_page(page, db.read_page(page))
      }
      FieldChunkReady(chunk) => return chunk
      _ => abort("未返回 BLOB 分块")
    }
  } nobreak {
    abort("字段分块循环未结束")
  }
}

///|
test "record header exposes physical offsets before reading field values" {
  let header = parse_record_header(b"\x03\x12\x13", 9)
  assert_eq(header.fields, [
    { index: 0, serial_type: 18UL, payload_offset: 3, byte_length: 3, },
    { index: 1, serial_type: 19UL, payload_offset: 6, byte_length: 3, },
  ])
  assert_true(
    try {
      ignore(parse_record_header(b"\x02\x7f", 4))
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(parse_record_header(b"\x03\x00\x00", 3, max_fields=1))
      false
    } catch {
      LimitExceeded(_) => true
      _ => false
    },
  )
}

///|
test "bounded field projection matches full records across encodings and overflow" {
  for
    bytes in [
      fixture_core(),
      fixture_btree(),
      fixture_utf16le(),
      fixture_utf16be(),
      fixture_page65536(),
    ] {
    let db = open_database(bytes)
    for entry in db.schema() {
      if entry.root_page == 0 {
        continue
      }
      let records : Array[BTreeRecord] = []
      ignore(
        db.scan_btree(
          entry.root_page,
          record => {
            records.push(record)
            true
          },
          limit=3,
        ),
      )
      for record in records {
        let full = db.preview_record(
          record.page_number,
          record.cell_offset,
          max_field_bytes=65536,
        )
        assert_eq(full.values.map(value => value.value), record.values)
        assert_true(full.record_complete)
        assert_true(full.overflow_chain_complete)
        let projection = db.preview_record(
          record.page_number,
          record.cell_offset,
          fields=Some([0]),
          max_field_bytes=16,
        )
        assert_eq(projection.values.length(), 1)
        assert_eq(projection.values[0].field.index, 0)
        if record.values.length() > 1 {
          assert_false(projection.record_complete)
        }
        for index = 0; index < record.values.length(); index = index + 1 {
          if record.values[index] is Blob(blob) {
            for offset in [0, blob.length() / 2, blob.length()] {
              let chunk = field_chunk(db, record, index, offset, 7)
              let length = Int::min(7, blob.length() - offset)
              assert_eq(chunk.bytes, blob[offset:offset + length].to_owned())
              assert_eq(chunk.more, offset + length < blob.length())
            }
          }
        }
      }
    }
  }
}

///|
test "text prefixes end at complete UTF8 and UTF16 codepoints" {
  for count in [0, 1, 2] {
    let data = b"\xe4\xb8\xad"
    assert_eq(prefix_text_bytes(data[0:count].to_owned(), 1, true), 0)
  }
  assert_eq(prefix_text_bytes(b"a\xf0\x9f\x8c", 1, true), 1)
  assert_eq(prefix_text_bytes(b"\x3c\xd8\x19\xdf", 2, true), 4)
  assert_eq(prefix_text_bytes(b"\x3c\xd8\x19", 2, true), 0)
  assert_eq(prefix_text_bytes(b"\xd8\x3c\xdf", 3, true), 0)
  assert_true(
    try {
      ignore(prefix_text_bytes(b"\xf0a", 1, true))
      false
    } catch {
      Invalid(_) => true
      _ => false
    },
  )
}

///|
test "field read stop and copy budget are enforced before allocating values" {
  let db = open_database(fixture_core())
  let records : Array[BTreeRecord] = []
  ignore(
    db.scan_btree(
      3,
      record => {
        records.push(record)
        true
      },
      limit=1,
    ),
  )
  let record = records[0]
  let cursor = db.field_cursor(
    record.page_number,
    record.cell_offset,
    max_total_copy_bytes=1UL,
  )
  cursor.provide_page(record.page_number, db.read_page(record.page_number))
  assert_true(
    try {
      ignore(cursor.next())
      false
    } catch {
      LimitExceeded(_) => true
      _ => false
    },
  )
  match cursor.next() {
    FieldReadFinished => ()
    _ => abort("失败后句柄没有结束")
  }
  let stopped = db.field_cursor(record.page_number, record.cell_offset)
  stopped.stop()
  match stopped.next() {
    FieldReadFinished => ()
    _ => abort("停止后仍请求页面")
  }
}

///|
test "field cursor freezes selection before caller mutates array" {
  let db = open_database(fixture_core())
  let records : Array[BTreeRecord] = []
  ignore(
    db.scan_btree(
      3,
      record => {
        records.push(record)
        true
      },
      limit=1,
    ),
  )
  let record = records[0]
  let indices = [0]
  let cursor = db.field_cursor(
    record.page_number,
    record.cell_offset,
    fields=Some(indices),
  )
  defer cursor.stop()
  indices.clear()
  while true {
    match cursor.next() {
      NeedFieldPage(page) => cursor.provide_page(page, db.read_page(page))
      FieldRecordReady(value) => {
        assert_eq(value.values.length(), 1)
        assert_eq(value.values[0].field.index, 0)
        break
      }
      _ => abort("字段游标未返回记录")
    }
  }
}

///|
test "projected scan keeps storage order without decoding whole payloads" {
  for
    bytes in [
      fixture_core(),
      fixture_btree(),
      fixture_utf16le(),
      fixture_utf16be(),
      fixture_page65536(),
    ] {
    let db = open_database(bytes)
    for entry in db.schema() {
      if entry.root_page == 0 {
        continue
      }
      let expected : Array[BTreeRecord] = []
      ignore(
        db.scan_btree(
          entry.root_page,
          record => {
            expected.push(record)
            true
          },
          limit=3,
        ),
      )
      let cursor = db.projected_cursor(
        entry.root_page,
        limit=3,
        max_field_bytes=16,
      )
      let actual : Array[ProjectedRecord] = []
      while true {
        match cursor.next() {
          NeedProjectedPage(page) =>
            cursor.provide_page(page, db.read_page(page))
          ProjectedRecordReady(record) => actual.push(record)
          ProjectedScanFinished(summary) => {
            assert_eq(summary.records_read, actual.length())
            break
          }
        }
      }
      assert_eq(actual.length(), expected.length())
      for index = 0; index < actual.length(); index = index + 1 {
        assert_eq(actual[index].rowid, expected[index].rowid)
        assert_eq(actual[index].page_number, expected[index].page_number)
        assert_eq(actual[index].cell_offset, expected[index].cell_offset)
        let independent = db.preview_record(
          expected[index].page_number,
          expected[index].cell_offset,
          max_field_bytes=16,
        )
        assert_eq(
          actual[index].values.map(value => value.value),
          independent.values.map(value => value.value),
        )
      }
      ignore(cursor.stop())
    }
  }
}
