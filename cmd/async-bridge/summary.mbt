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
