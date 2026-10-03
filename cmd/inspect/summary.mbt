///|
fn kind_text(kind : @sqlite.PageKind) -> String {
  match kind {
    @sqlite.BtreeRoot => "btree_root"
    @sqlite.BtreeChild => "btree_child"
    @sqlite.OverflowFirst => "overflow_first"
    @sqlite.OverflowContinuation => "overflow_continuation"
    @sqlite.FreelistTrunk => "freelist_trunk"
    @sqlite.FreelistLeaf => "freelist_leaf"
    @sqlite.PointerMap => "pointer_map"
    @sqlite.LockByte => "lock_byte"
  }
}

///|
fn summary_json(
  db : @sqlite.Database,
  report : @sqlite.DatabaseInspection,
) -> Json {
  let summary = report.summarize()
  let size = db.header().page_size.to_uint64()
  Json::object({
    "status": Json::string(status_text(report.status)),
    "ownership_complete": report.ownership_complete.to_json(),
    "ptrmap_checked": report.ptrmap_checked.to_json(),
    "diagnostics_truncated": report.diagnostics_truncated.to_json(),
    "logical_pages": db.page_count().to_json(),
    "page_size": db.header().page_size.to_json(),
    "claimed_pages": summary.claimed_pages.to_json(),
    "unclaimed_pages": summary.unclaimed_pages.to_json(),
    "roots_inspected": report.roots_inspected.to_json(),
    "records_decoded": report.records_decoded.to_json(),
    "payload_bytes": Json::string(report.payload_bytes.to_string()),
    "issue_count": report.issues.length().to_json(),
    "page_kinds": Json::array(
      summary.page_kinds.map(item => {
        Json::object({
          "kind": Json::string(kind_text(item.kind)),
          "pages": item.pages.to_json(),
        })
      }),
    ),
    "objects": Json::array(
      summary.objects.map(object => {
        Json::object({
          "root_page": object.root_page.to_json(),
          "object_name": match object.object_name {
            Some(name) => Json::string(name)
            None => Json::null()
          },
          "btree_pages": object.btree_pages.to_json(),
          "overflow_pages": object.overflow_pages.to_json(),
          "storage_bytes": Json::string(
            ((object.btree_pages + object.overflow_pages).to_uint64() * size).to_string(),
          ),
        })
      }),
    ),
  })
}

///|
fn summary_text(
  db : @sqlite.Database,
  details : @sqlite.DatabaseInspectionDetails,
) -> String {
  let report = details.inspection
  let summary = report.summarize()
  let out = StringBuilder()
  let status = match report.status {
    @sqlite.Complete => "完整（当前结构检查范围）"
    @sqlite.Failed => "失败"
    @sqlite.Incomplete => "未完成"
  }
  out.write_string("检查状态：\{status}\n")
  out.write_string(
    "逻辑页数：\{db.page_count()}，页大小：\{db.header().page_size} 字节\n",
  )
  let coverage = if report.ownership_complete {
    "完整"
  } else {
    "未完成，以下为已观察结果"
  }
  let ptrmap = if report.ptrmap_checked {
    "已核对或不适用"
  } else {
    "未完成"
  }
  let diagnostics = if report.diagnostics_truncated {
    "已截断"
  } else {
    "未截断"
  }
  out.write_string(
    "页归属：\{coverage}；Ptrmap：\{ptrmap}；诊断：\{diagnostics}\n",
  )
  out.write_string(
    "已认领页：\{summary.claimed_pages}，已枚举的未认领页：\{summary.unclaimed_pages}\n",
  )
  out.write_string(
    "已尝试根页：\{report.roots_inspected}，已解码记录：\{report.records_decoded}，已请求 payload：\{report.payload_bytes} 字节\n",
  )
  out.write_string("\n页面分类（已认领）：\n")
  for item in summary.page_kinds {
    if item.pages > 0 {
      out.write_string("  \{kind_text(item.kind)}：\{item.pages}\n")
    }
  }
  out.write_string("\n对象占页（已认领，含 sqlite_schema）：\n")
  for object in summary.objects {
    // 用 JSON 转义名称中的换行、制表符等，保证每个对象仍占一行。
    let name = match object.object_name {
      Some(name) => Json::string(name).stringify()
      None => "（未命名）"
    }
    let bytes = (object.btree_pages + object.overflow_pages).to_uint64() *
      db.header().page_size.to_uint64()
    out.write_string(
      "  \{name}，根页 \{object.root_page}：B-tree \{object.btree_pages}，overflow \{object.overflow_pages}，占页字节 \{bytes}\n",
    )
  }
  out.write_string("\n诊断：\{report.issues.length()} 条\n")
  for issue in details.issues {
    let message = match issue.issue {
      @sqlite.ScanError(root, error) => {
        let root = match root {
          None => "未知"
          Some(root) => root.to_string()
        }
        let message = match error {
          @sqlite.Invalid(message) => "错误：\{message}"
          @sqlite.Unsupported(message) => "未支持：\{message}"
          @sqlite.LimitExceeded(message) => "达到限额：\{message}"
        }
        "根页 \{root}，\{message}"
      }
      @sqlite.PageConflict(first, second) => {
        let first_name = object_label(first.object_name)
        let second_name = object_label(second.object_name)
        "页 \{first.page_number} 归属冲突：\{first_name} / \{second_name}"
      }
      @sqlite.UnclaimedPage(page) =>
        "页 \{page} 未认领（归属遍历已完成）"
      @sqlite.UnsupportedFeature(message) => message
      @sqlite.PtrmapMismatch(entry, _) =>
        "页 \{entry.page_number} 的 Ptrmap 与观察归属不一致"
    }
    let position = match issue.location {
      None => "位置未知"
      Some(location) => location_text(location)
    }
    out.write_string("  \{message}\n    \{position}\n")
  }
  out.to_string().trim_end().to_owned()
}

///|
fn object_label(name : String?) -> String {
  match name {
    Some(name) => Json::string(name).stringify()
    None => "（未命名）"
  }
}

///|
fn location_text(location : @sqlite.DiagnosticLocation) -> String {
  let phase = match location.phase {
    @sqlite.Configuration => "配置与预算"
    @sqlite.ReadPage => "页面读取"
    @sqlite.PageLayout => "页内布局"
    @sqlite.TreeTraversal => "树结构与键范围"
    @sqlite.CellPayload => "cell payload"
    @sqlite.OverflowChain => "overflow 链"
    @sqlite.RecordDecode => "记录解码"
    @sqlite.SchemaDecode => "schema 解码"
    @sqlite.FreelistCheck => "freelist 检查"
    @sqlite.PtrmapCheck => "Ptrmap 检查"
    @sqlite.PageOwnershipCheck => "页归属"
  }
  let text = StringBuilder()
  text.write_string("阶段：\{phase}")
  if location.page_number is Some(page) {
    text.write_string("，页：\{page}")
  }
  if location.byte_offset is Some(offset) {
    text.write_string("，页内偏移：\{offset}")
  }
  if location.cell_index is Some(index) {
    text.write_string("，cell 下标：\{index}")
  }
  text.to_string()
}
