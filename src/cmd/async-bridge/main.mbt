///|
// 桥接只交换请求、完整页面和序列化结果；所有格式及扫描状态仍由核心处理。
extern "js" fn register(call : (String, Bytes) -> String) -> Unit =
  #| call => { globalThis.moonsqlitefileAsyncBridge = (request, bytes = new Uint8Array(0)) => JSON.parse(call(JSON.stringify(request), bytes)); }

///|
priv struct BridgeSource {
  header : Bytes
  size : Int64
  mut offset : Int64
  mut bytes : Bytes
}

///|
impl @sqlite.RangeSource for BridgeSource with fn byte_length64(self) {
  self.size
}

///|
impl @sqlite.RangeSource for BridgeSource with fn read_range64(
  self,
  offset,
  count,
) {
  if offset == self.offset && count == self.bytes.length() {
    return self.bytes
  }
  if offset == 0L && count == 100 && self.header.length() == 100 {
    return self.header
  }
  raise @sqlite.HostFailure("异步桥接尚未供应此范围")
}

///|
priv struct BridgeIndex {
  snapshot : @sqlite.RangeWalSource
  base : BridgeSource
  wal : BridgeSource
}

///|
priv struct BridgeContext {
  db : @sqlite.Database
  source : BridgeSource
  index : BridgeIndex?
}

///|
priv struct BridgeScan {
  cursor : @sqlite.BTreeCursor
  owner : Int
  schema : Bool
}

///|
priv struct BridgeInspection {
  cursor : @sqlite.InspectionCursor
  owner : Int
}

///|
priv struct BridgeState {
  contexts : Map[Int, BridgeContext]
  scans : Map[Int, BridgeScan]
  inspections : Map[Int, BridgeInspection]
  wals : Map[Int, @sqlite.WalCursor]
  indexes : Map[Int, BridgeIndex]
  mut serial : Int
}

///|
fn BridgeState::id(self : BridgeState) -> Int raise @sqlite.SqliteError {
  if self.serial == 2147483647 ||
    self.contexts.length() +
    self.scans.length() +
    self.inspections.length() +
    self.wals.length() +
    self.indexes.length() >=
    1024 {
    raise @sqlite.LimitExceeded("异步桥接句柄上限已耗尽")
  }
  self.serial = self.serial + 1
  self.serial
}

///|
fn request_int(
  request : Map[String, Json],
  name : String,
  fallback : Int,
) -> Int raise @sqlite.SqliteError {
  @json.from_json(request.get(name).unwrap_or(fallback.to_json())) catch {
    _ => raise @sqlite.Invalid("参数 \{name} 必须为 Int")
  }
}

///|
fn request_text(
  request : Map[String, Json],
  name : String,
  fallback : String,
) -> String raise @sqlite.SqliteError {
  @json.from_json(request.get(name).unwrap_or(Json::string(fallback))) catch {
    _ => raise @sqlite.Invalid("参数 \{name} 必须为字符串")
  }
}

///|
fn request_uint(
  request : Map[String, Json],
  name : String,
  fallback : String,
  max_value : UInt64,
) -> UInt64 raise @sqlite.SqliteError {
  let text = request_text(request, name, fallback)
  if text.is_empty() {
    raise @sqlite.Invalid("整数参数不能为空")
  }
  let mut value = 0UL
  for character in text {
    if character < '0' || character > '9' {
      raise @sqlite.Invalid("整数参数只能包含十进制数字")
    }
    let digit = (character.to_int() - '0'.to_int()).to_uint64()
    if value > (max_value - digit) / 10UL {
      raise @sqlite.LimitExceeded("整数参数超出范围")
    }
    value = value * 10UL + digit
  }
  value
}

///|
fn request_limits(
  request : Map[String, Json],
) -> @sqlite.Limits raise @sqlite.SqliteError {
  {
    max_rows: request_int(request, "max_rows", 100000),
    max_pages: request_int(request, "max_pages", 100000),
    max_payload_bytes: request_int(request, "max_payload_bytes", 16777216),
    max_depth: request_int(request, "max_depth", 64),
  }
}

///|
fn scan_progress(progress : @sqlite.ScanProgress) -> Json {
  Json::object({
    "records_read": progress.records_read.to_json(),
    "pages_read": progress.pages_read.to_json(),
    "payload_bytes": Json::string(progress.payload_bytes.to_string()),
  })
}

///|
fn scan_summary(summary : @sqlite.ScanSummary) -> Json {
  Json::object({
    "records_read": summary.records_read.to_json(),
    "pages_read": summary.pages_read.to_json(),
    "payload_bytes": Json::string(summary.payload_bytes.to_string()),
    "completion": Json::string(
      match summary.completion {
        @sqlite.Complete => "complete"
        @sqlite.RecordLimit => "record_limit"
        @sqlite.VisitorStopped => "visitor_stopped"
      },
    ),
  })
}

///|
fn record_json(record : @sqlite.BTreeRecord) -> Json {
  Json::object({
    "rowid": match record.rowid {
      Some(rowid) => Json::string(rowid.to_string())
      None => Json::null()
    },
    "page_number": record.page_number.to_json(),
    "cell_offset": record.cell_offset.to_json(),
    "values": Json::array(record.values.map(value_json)),
  })
}

///|
fn dispatch(
  state : BridgeState,
  request : Map[String, Json],
  bytes : Bytes,
) -> Json raise @sqlite.SqliteError {
  let command = request_text(request, "op", "")
  let id = request_int(request, "id", 0)
  match command {
    "open" => {
      let size = request_uint(request, "size", "0", 9223372036854775807UL).reinterpret_as_int64()
      let source : BridgeSource = {
        size,
        header: bytes,
        offset: -1L,
        bytes: b"",
      }
      let db = @sqlite.open_range_source(
        source,
        limits=request_limits(request),
        max_report_pages=request_int(request, "max_report_pages", 100000),
      )
      let handle = state.id()
      state.contexts[handle] = { db, source, index: None, }
      Json::object({ "id": handle.to_json(), "header": header_json(db) })
    }
    "close" => {
      let scans = state.scans.keys().to_array()
      for scan_id in scans {
        if state.scans[scan_id].owner == id {
          ignore(state.scans[scan_id].cursor.stop())
          state.scans.remove(scan_id)
        }
      }
      state.contexts.remove(id)
      for inspection_id in state.inspections.keys().to_array() {
        if state.inspections[inspection_id].owner == id {
          ignore(state.inspections[inspection_id].cursor.stop())
          state.inspections.remove(inspection_id)
        }
      }
      Json::null()
    }
    "stats" =>
      Json::object({
        "contexts": state.contexts.length().to_json(),
        "scans": state.scans.length().to_json(),
        "inspections": state.inspections.length().to_json(),
        "wals": state.wals.length().to_json(),
        "indexes": state.indexes.length().to_json(),
      })
    "inspection-new" => {
      let context = state.contexts
        .get(id)
        .unwrap_or_else(() => raise @sqlite.Invalid("数据库句柄不存在"))
      let handle = state.id()
      let cursor = context.db.inspection_cursor(
        max_total_payload_bytes=request_uint(
          request, "max_total_payload_bytes", "67108864", 18446744073709551615UL,
        ),
        max_issues=request_int(request, "max_issues", 100),
      )
      state.inspections[handle] = { cursor, owner: id, }
      Json::object({ "id": handle.to_json() })
    }
    "inspection-next"
    | "inspection-supply"
    | "inspection-reject"
    | "inspection-close" => {
      let inspection = state.inspections
        .get(id)
        .unwrap_or_else(() => {
          raise @sqlite.Invalid("全库检查句柄不存在")
        })
      match command {
        "inspection-supply" => {
          inspection.cursor.provide_page(request_int(request, "page", 0), bytes)
          Json::null()
        }
        "inspection-reject" => {
          inspection.cursor.reject_page(
            @sqlite.Unsupported(
              request_text(request, "message", "source/host_failure"),
            ),
          )
          Json::null()
        }
        "inspection-close" => {
          let details = inspection.cursor.stop(
            reason=@sqlite.Unsupported(
              request_text(request, "message", "检查由宿主提前终止"),
            ),
          )
          let result = inspection_result(
            state.contexts[inspection.owner].db,
            details,
          )
          state.inspections.remove(id)
          result
        }
        _ =>
          match inspection.cursor.next() {
            @sqlite.NeedInspectionPage(number) =>
              Json::object({ "kind": "page", "page": number.to_json() })
            @sqlite.InspectionProgress(progress) =>
              Json::object({
                "kind": "progress",
                "progress": scan_progress(progress),
                "location": location_json(Some(inspection.cursor.location())),
              })
            @sqlite.InspectionFinished(details) =>
              Json::object({
                "kind": "done",
                "data": inspection_result(
                  state.contexts[inspection.owner].db,
                  details,
                ),
              })
          }
      }
    }
    "scan-new" => {
      let context = state.contexts
        .get(id)
        .unwrap_or_else(() => raise @sqlite.Invalid("数据库句柄不存在"))
      let handle = state.id()
      let cursor = context.db.scan_cursor(
        request_int(request, "root", 1),
        limit=request_int(request, "limit", context.db.limits.max_rows),
        max_total_payload_bytes=request_uint(
          request, "max_total_payload_bytes", "67108864", 18446744073709551615UL,
        ),
        table_only=request_text(request, "schema", "false") == "true",
      )
      state.scans[handle] = {
        cursor,
        owner: id,
        schema: request_text(request, "schema", "false") == "true",
      }
      Json::object({ "id": handle.to_json() })
    }
    "scan-next" | "scan-supply" | "scan-progress" | "scan-close" => {
      let scan = state.scans
        .get(id)
        .unwrap_or_else(() => raise @sqlite.Invalid("扫描句柄不存在"))
      let cursor = scan.cursor
      match command {
        "scan-supply" => {
          cursor.provide_page(request_int(request, "page", 0), bytes)
          Json::null()
        }
        "scan-progress" =>
          Json::object({
            "progress": scan_progress(cursor.progress()),
            "location": location_json(Some(cursor.location())),
          })
        "scan-close" => {
          let summary = cursor.stop()
          state.scans.remove(id)
          scan_summary(summary)
        }
        _ =>
          match cursor.next() {
            @sqlite.NeedPage(number) =>
              Json::object({ "kind": "page", "page": number.to_json() })
            @sqlite.RecordReady(record) if scan.schema => {
              let entry = @sqlite.decode_schema_entry(
                record.values,
                state.contexts[scan.owner].db.page_count(),
              )
              Json::object({
                "kind": "record",
                "record": {
                  "object_type": entry.object_type,
                  "name": entry.name,
                  "table_name": entry.table_name,
                  "root_page": entry.root_page,
                  "sql": match entry.sql {
                    Some(sql) => sql.to_json()
                    None => Json::null()
                  },
                },
                "progress": scan_progress(cursor.progress()),
              })
            }
            @sqlite.RecordReady(record) =>
              Json::object({
                "kind": "record",
                "record": record_json(record),
                "progress": scan_progress(cursor.progress()),
              })
            @sqlite.ScanFinished(summary) =>
              Json::object({ "kind": "done", "summary": scan_summary(summary) })
          }
      }
    }
    "page-inspect" => {
      let context = state.contexts
        .get(id)
        .unwrap_or_else(() => raise @sqlite.Invalid("数据库句柄不存在"))
      let number = request_int(request, "page", 0)
      let source = if context.index is Some(index) &&
        number > 0 &&
        number <= context.db.page_count() {
        match index.snapshot.page_range(number) {
          @sqlite.MainPage(offset) => {
            index.base.offset = offset
            index.base
          }
          @sqlite.WalPage(offset) => {
            index.wal.offset = offset
            index.wal
          }
        }
      } else {
        context.source.offset = (number - 1).to_int64() *
          context.db.header().page_size.to_int64()
        context.source
      }
      source.bytes = bytes
      defer {
        source.bytes = b""
        source.offset = -1L
      }
      page_inspection_json(context.db.inspect_page(number))
    }
    "wal-new" => {
      let cursor = @sqlite.WalCursor::new(
        request_uint(request, "size", "0", 9223372036854775807UL).reinterpret_as_int64(),
        max_frames=request_int(request, "max_frames", 100000),
      )
      let handle = state.id()
      state.wals[handle] = cursor
      Json::object({ "id": handle.to_json() })
    }
    "wal-next" | "wal-supply" | "wal-close" => {
      let cursor = state.wals
        .get(id)
        .unwrap_or_else(() => raise @sqlite.Invalid("WAL 句柄不存在"))
      match command {
        "wal-supply" => {
          cursor.provide(
            request_uint(request, "offset", "0", 9223372036854775807UL).reinterpret_as_int64(),
            bytes,
          )
          Json::null()
        }
        "wal-close" => {
          cursor.close()
          state.wals.remove(id)
          Json::null()
        }
        _ =>
          match cursor.next() {
            @sqlite.NeedWalRange(offset, count) =>
              Json::object({
                "kind": "range",
                "offset": Json::string(offset.to_string()),
                "count": count.to_json(),
                "frames_read": cursor.frames_read().to_json(),
              })
            @sqlite.WalReady(report) =>
              Json::object({ "kind": "done", "report": wal_json(report) })
          }
      }
    }
    "wal-index" => {
      let cursor = state.wals
        .get(id)
        .unwrap_or_else(() => raise @sqlite.Invalid("WAL 句柄不存在"))
      let base : BridgeSource = {
        header: bytes,
        size: request_uint(request, "base_size", "0", 9223372036854775807UL).reinterpret_as_int64(),
        offset: -1L,
        bytes: b"",
      }
      let wal : BridgeSource = {
        header: b"",
        size: request_uint(request, "wal_size", "0", 9223372036854775807UL).reinterpret_as_int64(),
        offset: -1L,
        bytes: b"",
      }
      let snapshot = @sqlite.RangeWalSource::from_cursor(
        base,
        wal,
        cursor,
        tail_policy=if request_text(request, "tail_policy", "strict") ==
          "valid_prefix" {
          @sqlite.UseValidPrefix
        } else {
          @sqlite.RejectInvalidTail
        },
        max_overlay_pages=request_int(request, "max_overlay_pages", 100000),
      )
      let handle = state.id()
      state.indexes[handle] = { snapshot, base, wal, }
      Json::object({
        "id": handle.to_json(),
        "size": Json::string(
          @sqlite.RangeSource::byte_length64(snapshot).to_string(),
        ),
        "page_count": snapshot.page_count().to_json(),
        "page_size": match snapshot.inspection().header {
          Some(header) => header.page_size.to_json()
          None => @sqlite.parse_header(bytes).page_size.to_json()
        },
      })
    }
    "index-page" | "index-open" | "index-close" => {
      let index = state.indexes
        .get(id)
        .unwrap_or_else(() => {
          raise @sqlite.Invalid("覆盖索引句柄不存在")
        })
      match command {
        "index-close" => {
          state.indexes.remove(id)
          Json::null()
        }
        "index-open" => {
          let source = match index.snapshot.page_range(1) {
            @sqlite.MainPage(offset) => {
              index.base.offset = offset
              index.base
            }
            @sqlite.WalPage(offset) => {
              index.wal.offset = offset
              index.wal
            }
          }
          source.bytes = bytes
          defer {
            source.bytes = b""
            source.offset = -1L
          }
          let db = @sqlite.open_range_wal_source(
            index.snapshot,
            limits=request_limits(request),
            max_report_pages=request_int(request, "max_report_pages", 100000),
          )
          let handle = state.id()
          state.contexts[handle] = { db, source, index: Some(index), }
          Json::object({ "id": handle.to_json(), "header": header_json(db) })
        }
        _ =>
          match index.snapshot.page_range(request_int(request, "page", 0)) {
            @sqlite.MainPage(offset) =>
              Json::object({
                "source": "base",
                "offset": Json::string(offset.to_string()),
              })
            @sqlite.WalPage(offset) =>
              Json::object({
                "source": "wal",
                "offset": Json::string(offset.to_string()),
              })
          }
      }
    }
    _ => raise @sqlite.Invalid("未知的异步桥接命令")
  }
}

///|
fn main {
  let state : BridgeState = {
    contexts: Map([]),
    scans: Map([]),
    inspections: Map([]),
    wals: Map([]),
    indexes: Map([]),
    serial: 0,
  }
  register((text, bytes) => {
    let result = try {
      let request : Map[String, Json] = @json.from_json(@json.parse(text)) catch {
        _ => raise @sqlite.Invalid("异步请求必须为 JSON 对象")
      }
      Json::object({ "ok": true, "result": dispatch(state, request, bytes) })
    } catch {
      @sqlite.Invalid(message) =>
        Json::object({
          "ok": false,
          "error": { "kind": "invalid", "message": message },
        })
      @sqlite.Unsupported(message) =>
        Json::object({
          "ok": false,
          "error": { "kind": "unsupported", "message": message },
        })
      @sqlite.LimitExceeded(message) =>
        Json::object({
          "ok": false,
          "error": { "kind": "limit_exceeded", "message": message },
        })
    }
    result.stringify()
  })
}
