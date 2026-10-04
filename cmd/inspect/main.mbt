///|
suberror CliError {
  Usage(String)
}

///|
// JavaScript 桥接仅提供进程参数和字节输入；文件格式解析全部在 MoonBit 中进行。
extern "js" fn host_args() -> FixedArray[String] =
  #| () => globalThis.moonsqlitefileHost.args

///|
extern "js" fn host_bytes() -> Bytes =
  #| () => globalThis.moonsqlitefileHost.bytes

///|
extern "js" fn host_output(text : String) -> Unit =
  #| text => globalThis.moonsqlitefileHost.output(text)

///|
extern "js" fn host_error(text : String) -> Unit =
  #| text => globalThis.moonsqlitefileHost.error(text)

///|
extern "js" fn host_exit_code(code : Int) -> Unit =
  #| code => globalThis.moonsqlitefileHost.exitCode(code)

///|
fn parse_number(text : String, allow_zero : Bool) -> Int raise CliError {
  if text.is_empty() {
    raise Usage("数字参数不能为空")
  }
  let mut value = 0
  for character in text {
    if character < '0' || character > '9' {
      raise Usage("数字参数只能包含十进制数字：\{text}")
    }
    let digit = character.to_int() - '0'.to_int()
    if value > (2147483647 - digit) / 10 {
      raise Usage("数字参数超出 Int 范围：\{text}")
    }
    value = value * 10 + digit
  }
  if value == 0 && !allow_zero {
    raise Usage("页号必须大于零")
  }
  value
}

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
fn run(args : FixedArray[String]) -> Json raise {
  let usage = "用法：node tools/inspect.cjs FILE [--wal WAL [--wal-prefix]] header|schema|page N|page-inspect N|rows TABLE [LIMIT]|records TABLE [LIMIT]|index INDEX [LIMIT]|scan ROOT [LIMIT]|freelist|inspect|inspect-details|tree-inspect ROOT [LIMIT]|summary|summary-json|viewer-data|wal-inspect|wal-info"
  if args.length() < 2 {
    raise Usage(usage)
  }
  let command = args[1]
  match command {
    "header"
    | "schema"
    | "freelist"
    | "inspect"
    | "inspect-details"
    | "summary-json"
    | "wal-inspect"
    | "wal-info"
    | "viewer-data" => if args.length() != 2 { raise Usage(usage) }
    "page" | "page-inspect" => if args.length() != 3 { raise Usage(usage) }
    "rows" | "records" | "index" | "scan" | "tree-inspect" =>
      if args.length() != 3 && args.length() != 4 {
        raise Usage(usage)
      }
    _ => raise Usage("未知命令：\{command}\n\{usage}")
  }
  if command == "wal-inspect" {
    if host_has_wal() {
      raise Usage("wal-inspect 直接接收 WAL 文件，不接受 --wal")
    }
    let report = @sqlite.inspect_wal(host_bytes())
    host_exit_code(
      match report.stop_reason {
        @sqlite.WalEndOfFile => 0
        @sqlite.WalFrameLimit => 2
        _ => 1
      },
    )
    return wal_json(report)
  }
  if command == "wal-info" && !host_has_wal() {
    raise Usage("wal-info 必须提供 --wal WAL")
  }
  let (db, wal) = cli_database()
  match command {
    "wal-info" =>
      Json::object({
        "wal": wal_json(wal.unwrap().inspection()),
        "snapshot": header_json(db),
        "tail_policy": Json::string(
          if host_wal_prefix() {
            "valid_prefix"
          } else {
            "strict"
          },
        ),
      })
    "header" => header_json(db)
    "schema" => {
      let entries = db.schema()
      Json::array(
        entries.map(entry => {
          Json::object({
            "object_type": Json::string(entry.object_type),
            "name": Json::string(entry.name),
            "table_name": Json::string(entry.table_name),
            "root_page": entry.root_page.to_json(),
            "sql": match entry.sql {
              Some(text) => Json::string(text)
              None => Json::null()
            },
          })
        }),
      )
    }
    "page" => page_json(db.page(parse_number(args[2], false)))
    "page-inspect" => {
      let report = db.inspect_page(parse_number(args[2], false))
      host_exit_code(
        match report.status {
          @sqlite.Complete => 0
          @sqlite.Failed => 1
          @sqlite.Incomplete => 2
        },
      )
      page_inspection_json(report)
    }
    "rows" => {
      let rows = if args.length() == 4 {
        db.table_rows(args[2], limit=parse_number(args[3], true))
      } else {
        db.table_rows(args[2])
      }
      Json::array(
        rows.map(row => {
          Json::object({
            // 值按 record 存储顺序输出，不推断 INTEGER PRIMARY KEY 等 SQL 语义。
            "rowid": Json::string(row.rowid.to_string()),
            "page_number": row.page_number.to_json(),
            "values": Json::array(row.values.map(value_json)),
          })
        }),
      )
    }
    "records" | "index" => {
      let records = if command == "index" {
        if args.length() == 4 {
          db.index_records(args[2], limit=parse_number(args[3], true))
        } else {
          db.index_records(args[2])
        }
      } else if args.length() == 4 {
        db.table_records(args[2], limit=parse_number(args[3], true))
      } else {
        db.table_records(args[2])
      }
      Json::array(
        records.map(record => {
          Json::object({
            "rowid": match record.rowid {
              Some(rowid) => Json::string(rowid.to_string())
              None => Json::null()
            },
            "page_number": record.page_number.to_json(),
            "cell_offset": record.cell_offset.to_json(),
            "values": Json::array(record.values.map(value_json)),
          })
        }),
      )
    }
    "scan" => {
      let root = parse_number(args[2], false)
      let summary = if args.length() == 4 {
        db.scan_btree(root, _ => true, limit=parse_number(args[3], true))
      } else {
        db.scan_btree(root, _ => true)
      }
      let completion = match summary.completion {
        @sqlite.Complete => "complete"
        @sqlite.RecordLimit => "record_limit"
        @sqlite.VisitorStopped => "visitor_stopped"
      }
      Json::object({
        "records_read": summary.records_read.to_json(),
        "pages_read": summary.pages_read.to_json(),
        "payload_bytes": Json::string(summary.payload_bytes.to_string()),
        "completion": Json::string(completion),
      })
    }
    "freelist" => db.freelist().to_json()
    "viewer-data" => {
      let details = db.inspect_database_details()
      report_exit(details.inspection.status)
      Json::object({
        "header": header_json(db),
        "summary": summary_json(db, details.inspection),
        "inspection": inspection_json(details.inspection),
        "locations": Json::array(
          details.issues.map(issue => location_json(issue.location)),
        ),
      })
    }
    "summary-json" => {
      let report = db.inspect_database()
      report_exit(report.status)
      summary_json(db, report)
    }
    "inspect-details" => {
      let details = db.inspect_database_details()
      report_exit(details.inspection.status)
      Json::object({
        "inspection": inspection_json(details.inspection),
        "locations": Json::array(
          details.issues.map(issue => location_json(issue.location)),
        ),
      })
    }
    "tree-inspect" => {
      let root = parse_number(args[2], false)
      let details = if args.length() == 4 {
        db.inspect_btree_details(root, limit=parse_number(args[3], true))
      } else {
        db.inspect_btree_details(root)
      }
      let report = details.inspection
      report_exit(report.status)
      let error = match report.error {
        None => Json::null()
        Some(error) => {
          let (kind, message) = match error {
            @sqlite.Invalid(message) => ("invalid", message)
            @sqlite.Unsupported(message) => ("unsupported", message)
            @sqlite.LimitExceeded(message) => ("limit_exceeded", message)
          }
          Json::object({
            "error_kind": Json::string(kind),
            "message": Json::string(message),
          })
        }
      }
      Json::object({
        "root_page": root.to_json(),
        "status": Json::string(status_text(report.status)),
        "records_decoded": report.records_decoded.to_json(),
        "completion": match report.summary {
          None => Json::null()
          Some(summary) =>
            Json::string(
              match summary.completion {
                @sqlite.Complete => "complete"
                @sqlite.RecordLimit => "record_limit"
                @sqlite.VisitorStopped => "visitor_stopped"
              },
            )
        },
        "error": error,
        "location": location_json(details.location),
      })
    }
    "inspect" => {
      let report = db.inspect_database()
      // JSON 报告始终保留在 stdout，退出码区分完整、失败和未完成。
      host_exit_code(
        match report.status {
          @sqlite.Complete => 0
          @sqlite.Failed => 1
          @sqlite.Incomplete => 2
        },
      )
      inspection_json(report)
    }
    _ => raise Usage(usage)
  }
}

///|
fn ownership_json(page : @sqlite.PageOwnership) -> Json {
  let kind = kind_text(page.kind)
  Json::object({
    "page_number": page.page_number.to_json(),
    "kind": Json::string(kind),
    "root_page": match page.root_page {
      Some(number) => number.to_json()
      None => Json::null()
    },
    "object_name": match page.object_name {
      Some(name) => name.to_json()
      None => Json::null()
    },
    "parent_page": match page.parent_page {
      Some(number) => number.to_json()
      None => Json::null()
    },
  })
}

///|
fn inspection_json(report : @sqlite.DatabaseInspection) -> Json {
  let status = match report.status {
    @sqlite.Complete => "complete"
    @sqlite.Incomplete => "incomplete"
    @sqlite.Failed => "failed"
  }
  let issues = report.issues.map(issue => {
    match issue {
      @sqlite.ScanError(root, error) => {
        let (kind, message) = match error {
          @sqlite.Invalid(message) => ("invalid", message)
          @sqlite.Unsupported(message) => ("unsupported", message)
          @sqlite.LimitExceeded(message) => ("limit_exceeded", message)
        }
        Json::object({
          "code": "scan_error",
          "root_page": match root {
            Some(number) => number.to_json()
            None => Json::null()
          },
          "error_kind": Json::string(kind),
          "message": Json::string(message),
        })
      }
      @sqlite.PageConflict(first, second) =>
        Json::object({
          "code": "page_conflict",
          "first": ownership_json(first),
          "second": ownership_json(second),
        })
      @sqlite.UnclaimedPage(number) =>
        Json::object({
          "code": "unclaimed_page",
          "page_number": number.to_json(),
        })
      @sqlite.UnsupportedFeature(message) =>
        Json::object({
          "code": "unsupported_feature",
          "message": Json::string(message),
        })
      @sqlite.PtrmapMismatch(entry, owner) =>
        Json::object({
          "code": "ptrmap_mismatch",
          "page_number": entry.page_number.to_json(),
          "map_page": entry.map_page.to_json(),
          "ptrmap_type": (match entry.kind {
            @sqlite.RootPage => 1
            @sqlite.FreePage => 2
            @sqlite.FirstOverflow => 3
            @sqlite.NextOverflow => 4
            @sqlite.NonRootBtree => 5
          }).to_json(),
          "parent_page": entry.parent_page.to_json(),
          "expected_owner": ownership_json(owner),
        })
    }
  })
  Json::object({
    "status": Json::string(status),
    "ownership_complete": report.ownership_complete.to_json(),
    "ptrmap_checked": report.ptrmap_checked.to_json(),
    "diagnostics_truncated": report.diagnostics_truncated.to_json(),
    "roots_inspected": report.roots_inspected.to_json(),
    "records_decoded": report.records_decoded.to_json(),
    "payload_bytes": Json::string(report.payload_bytes.to_string()),
    "pages": Json::array(report.pages.map(ownership_json)),
    "unclaimed_pages": report.unclaimed_pages.to_json(),
    "issues": Json::array(issues),
  })
}

///|
fn main {
  try {
    let args = host_args()
    if args.length() >= 2 && args[1] == "summary" {
      if args.length() != 2 {
        raise Usage("用法：node tools/inspect.cjs FILE summary")
      }
      let (db, _) = cli_database()
      let details = db.inspect_database_details()
      report_exit(details.inspection.status)
      host_output(summary_text(db, details))
    } else {
      let result = run(args)
      host_output(result.stringify())
    }
  } catch {
    Usage(message) => host_error(message)
    error => host_error("\{error}")
  }
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
fn status_text(status : @sqlite.InspectionStatus) -> String {
  match status {
    @sqlite.Complete => "complete"
    @sqlite.Failed => "failed"
    @sqlite.Incomplete => "incomplete"
  }
}

///|
fn report_exit(status : @sqlite.InspectionStatus) -> Unit {
  host_exit_code(
    match status {
      @sqlite.Complete => 0
      @sqlite.Failed => 1
      @sqlite.Incomplete => 2
    },
  )
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
