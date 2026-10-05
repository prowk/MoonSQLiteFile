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
fn inspection_result(
  db : @sqlite.Database,
  details : @sqlite.DatabaseInspectionDetails,
) -> Json {
  Json::object({
    "header": header_json(db),
    "inspection": inspection_json(details.inspection),
    "summary": summary_json(db, details.inspection),
    "locations": Json::array(
      details.issues.map(issue => location_json(issue.location)),
    ),
  })
}

///|
fn status_text(status : @sqlite.InspectionStatus) -> String {
  match status {
    @sqlite.Complete => "complete"
    @sqlite.Failed => "failed"
    @sqlite.Incomplete => "incomplete"
  }
}
