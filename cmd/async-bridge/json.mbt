///|
fn blob_hex(bytes : Bytes) -> String {
  let digits = "0123456789abcdef"
  let builder = StringBuilder()
  for byte in bytes {
    let value = byte.to_int()
    builder.write_char(digits[value >> 4].to_char().unwrap())
    builder.write_char(digits[value & 15].to_char().unwrap())
  }
  builder.to_string()
}

///|
fn value_json(value : @sqlite.Value) -> Json {
  let (kind, data) : (String, Json) = match value {
    @sqlite.Null => ("null", Json::null())
    @sqlite.Integer(number) => ("integer", Json::string(number.to_string()))
    @sqlite.Real(number) => {
      // 非有限 IEEE 值使用字符串保留，避免生成无效 JSON 数字。
      let data = if number.is_nan() {
        Json::string("NaN")
      } else if number.is_pos_inf() {
        Json::string("Infinity")
      } else if number.is_neg_inf() {
        Json::string("-Infinity")
      } else {
        Json::number(number)
      }
      ("real", data)
    }
    @sqlite.Text(text) => ("text", Json::string(text))
    @sqlite.Blob(bytes) => ("blob", Json::string(blob_hex(bytes)))
  }
  Json::object({ "type": Json::string(kind), "value": data })
}

///|
fn header_json(db : @sqlite.Database) -> Json {
  let h = db.header()
  Json::object({
    "page_size": h.page_size.to_json(),
    "usable_size": h.usable_size.to_json(),
    "page_count": db.page_count().to_json(),
    "write_version": h.write_version.to_json(),
    "read_version": h.read_version.to_json(),
    "change_counter": h.change_counter.to_json(),
    "declared_pages": h.declared_pages.to_json(),
    "freelist_trunk": h.freelist_trunk.to_json(),
    "freelist_pages": h.freelist_pages.to_json(),
    "schema_cookie": h.schema_cookie.to_json(),
    "schema_format": h.schema_format.to_json(),
    "largest_root_page": h.largest_root_page.to_json(),
    "incremental_vacuum": h.incremental_vacuum.to_json(),
    "text_encoding": h.text_encoding.to_json(),
    "user_version": h.user_version.to_json(),
    "application_id": h.application_id.to_json(),
    "version_valid_for": h.version_valid_for.to_json(),
    "sqlite_version": h.sqlite_version.to_json(),
  })
}

///|
fn page_json(page : @sqlite.Page) -> Json {
  let kind = match page.kind {
    @sqlite.TableLeaf => "table_leaf"
    @sqlite.TableInterior => "table_interior"
    @sqlite.IndexLeaf => "index_leaf"
    @sqlite.IndexInterior => "index_interior"
  }
  Json::object({
    "number": page.number.to_json(),
    "kind": Json::string(kind),
    "first_freeblock": page.first_freeblock.to_json(),
    "cell_count": page.cell_count.to_json(),
    "content_start": page.content_start.to_json(),
    "fragmented_bytes": page.fragmented_bytes.to_json(),
    "right_child": match page.right_child {
      Some(number) => number.to_json()
      None => Json::null()
    },
    "cell_offsets": page.cell_offsets.to_json(),
  })
}

///|
fn page_inspection_json(report : @sqlite.PageInspection) -> Json {
  let status = match report.status {
    @sqlite.Complete => "complete"
    @sqlite.Failed => "failed"
    @sqlite.Incomplete => "incomplete"
  }
  let statistics = match report.statistics {
    None => Json::null()
    Some(stats) =>
      Json::object({
        "database_header_bytes": stats.database_header_bytes.to_json(),
        "btree_header_bytes": stats.btree_header_bytes.to_json(),
        "pointer_bytes": stats.pointer_bytes.to_json(),
        "unallocated_bytes": stats.unallocated_bytes.to_json(),
        "cell_bytes": stats.cell_bytes.to_json(),
        "freeblock_bytes": stats.freeblock_bytes.to_json(),
        "fragmented_bytes": stats.fragmented_bytes.to_json(),
        "reserved_bytes": stats.reserved_bytes.to_json(),
        "payload_bytes": Json::string(stats.payload_bytes.to_string()),
        "local_payload_bytes": Json::string(
          stats.local_payload_bytes.to_string(),
        ),
        "max_payload_bytes": stats.max_payload_bytes.to_json(),
        "overflow_cells": stats.overflow_cells.to_json(),
      })
  }
  let diagnostic = match report.diagnostic {
    None => Json::null()
    Some(diagnostic) => {
      let code = page_code_text(diagnostic.code)
      let (kind, message) = match diagnostic.error {
        @sqlite.Invalid(message) => ("invalid", message)
        @sqlite.Unsupported(message) => ("unsupported", message)
        @sqlite.LimitExceeded(message) => ("limit_exceeded", message)
      }
      Json::object({
        "code": Json::string(code),
        "page_number": diagnostic.page_number.to_json(),
        "byte_offset": match diagnostic.byte_offset {
          Some(offset) => offset.to_json()
          None => Json::null()
        },
        "cell_index": match diagnostic.cell_index {
          Some(index) => index.to_json()
          None => Json::null()
        },
        "error_kind": Json::string(kind),
        "message": Json::string(message),
      })
    }
  }
  Json::object({
    "status": Json::string(status),
    "page": match report.page {
      Some(page) => page_json(page)
      None => Json::null()
    },
    "statistics": statistics,
    "diagnostic": diagnostic,
  })
}

///|
fn page_code_text(code : @sqlite.PageDiagnosticCode) -> String {
  match code {
    @sqlite.PageRead => "page_read"
    @sqlite.PageTypeTag => "page_type_tag"
    @sqlite.PageHeader => "page_header"
    @sqlite.CellPointer => "cell_pointer"
    @sqlite.CellFormat => "cell_format"
    @sqlite.Freeblock => "freeblock"
    @sqlite.SpaceOverlap => "space_overlap"
    @sqlite.UntrackedSpace => "untracked_space"
    @sqlite.FragmentCount => "fragment_count"
    @sqlite.ChildPointer => "child_pointer"
  }
}

///|
fn location_json(location : @sqlite.DiagnosticLocation?) -> Json {
  match location {
    None => Json::null()
    Some(location) => {
      let phase = match location.phase {
        @sqlite.Configuration => "configuration"
        @sqlite.ReadPage => "read_page"
        @sqlite.PageLayout => "page_layout"
        @sqlite.TreeTraversal => "tree_traversal"
        @sqlite.CellPayload => "cell_payload"
        @sqlite.OverflowChain => "overflow_chain"
        @sqlite.RecordDecode => "record_decode"
        @sqlite.SchemaDecode => "schema_decode"
        @sqlite.FreelistCheck => "freelist_check"
        @sqlite.PtrmapCheck => "ptrmap_check"
        @sqlite.PageOwnershipCheck => "page_ownership_check"
      }
      Json::object({
        "phase": Json::string(phase),
        "page_number": match location.page_number {
          Some(number) => number.to_json()
          None => Json::null()
        },
        "byte_offset": match location.byte_offset {
          Some(offset) => offset.to_json()
          None => Json::null()
        },
        "cell_index": match location.cell_index {
          Some(index) => index.to_json()
          None => Json::null()
        },
        "page_code": match location.page_diagnostic {
          Some(diagnostic) => Json::string(page_code_text(diagnostic.code))
          None => Json::null()
        },
      })
    }
  }
}
