///|
pub(all) enum PageKind {
  BtreeRoot
  BtreeChild
  OverflowFirst
  OverflowContinuation
  FreelistTrunk
  FreelistLeaf
  PointerMap
  LockByte
} derive(Debug, Eq)

///|
pub extend PageKind with @debug.Debug::{to_repr}

///|
pub extend PageKind with Eq::{equal, not_equal}

///|
pub(all) struct PageOwnership {
  page_number : Int
  kind : PageKind
  root_page : Int?
  object_name : String?
  parent_page : Int?
} derive(Debug, Eq)

///|
pub extend PageOwnership with @debug.Debug::{to_repr}

///|
pub extend PageOwnership with Eq::{equal, not_equal}

///|
pub(all) enum DatabaseIssue {
  ScanError(Int?, SqliteError)
  PageConflict(PageOwnership, PageOwnership)
  UnclaimedPage(Int)
  UnsupportedFeature(String)
  PtrmapMismatch(PtrmapEntry, PageOwnership)
} derive(Debug)

///|
pub extend DatabaseIssue with @debug.Debug::{to_repr}

///|
/// 只检查逻辑数据库页；完整页归属不等价于 SQL 完整性检查。
pub(all) struct DatabaseInspection {
  status : InspectionStatus
  ownership_complete : Bool
  ptrmap_checked : Bool
  diagnostics_truncated : Bool
  roots_inspected : Int
  records_decoded : Int
  payload_bytes : UInt64
  pages : Array[PageOwnership]
  unclaimed_pages : Array[Int]
  issues : Array[DatabaseIssue]
} derive(Debug)

///|
pub extend DatabaseInspection with @debug.Debug::{to_repr}

///|
priv struct OwnershipState {
  owners : Map[Int, PageOwnership]
  issues : Array[DatabaseIssue]
  located_issues : Array[LocatedDatabaseIssue]
  trace : InspectionTrace
  max_pages : Int
  max_issues : Int
  mut coverage : Bool
  mut failed : Bool
  mut truncated : Bool
  mut roots : Int
  mut records : Int
  mut payload : UInt64
}

///|
fn OwnershipState::issue(self : OwnershipState, issue : DatabaseIssue) -> Unit {
  if self.issues.length() < self.max_issues {
    let location : DiagnosticLocation? = match issue {
      PageConflict(_, owner) =>
        Some({
          phase: PageOwnershipCheck,
          page_number: Some(owner.page_number),
          byte_offset: None,
          cell_index: None,
          page_diagnostic: None,
        })
      UnclaimedPage(number) =>
        Some({
          phase: PageOwnershipCheck,
          page_number: Some(number),
          byte_offset: None,
          cell_index: None,
          page_diagnostic: None,
        })
      UnsupportedFeature(_) => None
      _ => Some(self.trace.snapshot())
    }
    self.issues.push(issue)
    self.located_issues.push({ issue, location, })
  } else {
    self.truncated = true
  }
}

///|
fn OwnershipState::error(
  self : OwnershipState,
  root : Int?,
  error : SqliteError,
) -> Unit {
  self.coverage = false
  if error is Invalid(_) {
    self.failed = true
  }
  self.issue(ScanError(root, error))
}

///|
fn OwnershipState::claim(
  self : OwnershipState,
  owner : PageOwnership,
) -> Unit raise SqliteError {
  if self.owners.get(owner.page_number) is Some(previous) {
    self.failed = true
    self.issue(PageConflict(previous, owner))
    raise Invalid("页 \{owner.page_number} 被多个用途或对象占用")
  }
  if self.owners.length() >= self.max_pages {
    raise LimitExceeded("数据库级页数预算已耗尽")
  }
  self.owners[owner.page_number] = owner
}

///|
fn OwnershipState::observer(
  self : OwnershipState,
  root : Int,
  name : String,
) -> ScanObserver {
  {
    claim: (number, kind, parent) => {
      self.claim({
        page_number: number,
        kind,
        root_page: Some(root),
        object_name: Some(name),
        parent_page: parent,
      })
    },
    charge_payload: size => self.payload = self.payload + size,
    trace: self.trace,
  }
}

///|
fn OwnershipState::finish(
  self : OwnershipState,
  page_count : Int,
  ptrmap_checked : Bool,
) -> DatabaseInspection {
  let pages : Array[PageOwnership] = []
  let unclaimed : Array[Int] = []
  // 预检拒绝超预算的数据库，避免枚举或分配无界的页列表。
  if page_count <= self.max_pages {
    for index = 0; index < page_count; index = index + 1 {
      let number = index + 1
      if self.owners.get(number) is Some(owner) {
        pages.push(owner)
      } else {
        unclaimed.push(number)
        if self.coverage {
          self.failed = true
          self.issue(UnclaimedPage(number))
        }
      }
    }
  }
  let status = if self.failed {
    Failed
  } else if !self.coverage || !ptrmap_checked || self.truncated {
    Incomplete
  } else {
    Complete
  }
  {
    status,
    ownership_complete: self.coverage,
    ptrmap_checked,
    diagnostics_truncated: self.truncated,
    roots_inspected: self.roots,
    records_decoded: self.records,
    payload_bytes: self.payload,
    pages,
    unclaimed_pages: unclaimed,
    issues: self.issues,
  }
}

///|
/// 扫描 schema、独立 B-tree 和 freelist，使用整个检查过程共享的预算。
pub fn Database::inspect_database(
  self : Database,
  max_total_payload_bytes? : UInt64 = 67108864UL,
  max_issues? : Int = 100,
) -> DatabaseInspection {
  self.inspect_database_traced([], max_total_payload_bytes~, max_issues~)
}

///|
fn Database::inspect_database_traced(
  self : Database,
  located_issues : Array[LocatedDatabaseIssue],
  max_total_payload_bytes~ : UInt64,
  max_issues~ : Int,
) -> DatabaseInspection {
  let state : OwnershipState = {
    owners: Map([]),
    issues: [],
    located_issues,
    trace: InspectionTrace::new(),
    max_pages: Int::min(self.limits.max_pages, self.report_max_pages),
    max_issues: if max_issues > 0 {
      max_issues
    } else {
      1
    },
    coverage: true,
    failed: false,
    truncated: false,
    roots: 0,
    records: 0,
    payload: 0UL,
  }
  let vacuum = self.header.largest_root_page != 0U
  if max_issues < 1 {
    state.error(None, Invalid("诊断条数上限必须为正数"))
    return state.finish(0, !vacuum)
  }
  if self.page_count > state.max_pages {
    state.error(
      None,
      LimitExceeded("数据库逻辑页数超过全局检查预算"),
    )
    return state.finish(self.page_count, false)
  }
  if self.header.largest_root_page.to_uint64() > self.page_count.to_uint64() ||
    (!vacuum && self.header.incremental_vacuum) {
    state.trace.at(Configuration, Some(1), byte_offset=Some(52))
    state.error(None, Invalid("auto-vacuum 文件头字段不一致"))
    return state.finish(self.page_count, false)
  }
  let lock_page = 1073741824 / self.header.page_size + 1
  if lock_page <= self.page_count {
    // 这些保留页仅按位置认领，不执行 B-tree 解码。
    state.claim({
      page_number: lock_page,
      kind: LockByte,
      root_page: None,
      object_name: None,
      parent_page: None,
    }) catch {
      Invalid(message) => state.error(None, Invalid(message))
      LimitExceeded(message) => state.error(None, LimitExceeded(message))
      Unsupported(message) => state.error(None, Unsupported(message))
    }
  }
  if vacuum {
    let step = self.header.usable_size / 5 + 1
    let mut number = 2
    while number <= self.page_count {
      let actual = if number == lock_page { number + 1 } else { number }
      if actual <= self.page_count {
        state.claim({
          page_number: actual,
          kind: PointerMap,
          root_page: None,
          object_name: None,
          parent_page: None,
        }) catch {
          Invalid(message) => state.error(None, Invalid(message))
          LimitExceeded(message) => state.error(None, LimitExceeded(message))
          Unsupported(message) => state.error(None, Unsupported(message))
        }
      }
      if self.page_count - number < step {
        break
      }
      number = number + step
    }
  }
  let entries : Array[SchemaEntry] = []
  state.roots = state.roots + 1
  let schema_ok = try {
    let kind = self.page_traced(1, state.trace).kind
    state.trace.at(SchemaDecode, Some(1), byte_offset=Some(100))
    if kind != TableLeaf && kind != TableInterior {
      raise Invalid("sqlite_schema 根页必须是 table B-tree")
    }
    let summary = self.scan_btree_observed(
      1,
      record => {
        state.records = state.records + 1
        state.trace.at(
          SchemaDecode,
          Some(record.page_number),
          byte_offset=Some(record.cell_offset),
          cell_index=state.trace.cell_index,
        )
        entries.push(schema_entry(record.values, self.page_count))
        true
      },
      state.observer(1, "sqlite_schema"),
      limit=self.limits.max_rows,
      max_total_payload_bytes~,
    )
    if summary.completion != Complete {
      state.trace.at(SchemaDecode, None)
      state.error(
        Some(1),
        LimitExceeded("schema 未完整读取，无法发现全部根页"),
      )
      false
    } else {
      true
    }
  } catch {
    Invalid(message) => {
      state.error(Some(1), Invalid(message))
      false
    }
    Unsupported(message) => {
      state.error(Some(1), Unsupported(message))
      false
    }
    LimitExceeded(message) => {
      state.error(Some(1), LimitExceeded(message))
      false
    }
  }
  if !schema_ok {
    return state.finish(self.page_count, !vacuum)
  }
  for entry in entries {
    state.trace.at(SchemaDecode, None)
    if state.issues.length() >= state.max_issues {
      state.coverage = false
      state.truncated = true
      break
    }
    if entry.object_type == "view" || entry.object_type == "trigger" {
      if entry.root_page != 0 {
        state.error(
          Some(entry.root_page),
          Invalid("view 或 trigger 不能拥有根页"),
        )
      }
      continue
    }
    if entry.root_page == 0 {
      if entry.object_type == "index" {
        state.error(Some(0), Invalid("索引没有根页"))
      }
      // 虚拟表定义不占独立 B-tree，shadow 表仍按 schema 独立扫描。
      continue
    }
    state.roots = state.roots + 1
    try {
      if entry.object_type == "index" {
        let kind = self.page_traced(entry.root_page, state.trace).kind
        state.trace.at(SchemaDecode, Some(entry.root_page))
        if kind != IndexLeaf && kind != IndexInterior {
          raise Invalid("schema 索引根页不是 index B-tree")
        }
      }
      let summary = self.scan_btree_observed(
        entry.root_page,
        _ => {
          state.records = state.records + 1
          true
        },
        state.observer(entry.root_page, entry.name),
        limit=self.limits.max_rows - state.records,
        max_total_payload_bytes=max_total_payload_bytes - state.payload,
      )
      if summary.completion != Complete {
        state.trace.at(Configuration, Some(entry.root_page))
        state.error(
          Some(entry.root_page),
          LimitExceeded("全局记录数预算已耗尽"),
        )
      }
    } catch {
      Invalid(message) => state.error(Some(entry.root_page), Invalid(message))
      Unsupported(message) =>
        state.error(Some(entry.root_page), Unsupported(message))
      LimitExceeded(message) =>
        state.error(Some(entry.root_page), LimitExceeded(message))
    }
  }
  if state.issues.length() < state.max_issues {
    ignore(
      self.freelist_observed(
        (number, kind, parent) => {
          state.claim({
            page_number: number,
            kind,
            root_page: None,
            object_name: None,
            parent_page: parent,
          })
        },
        trace=state.trace,
      ),
    ) catch {
      Invalid(message) => state.error(None, Invalid(message))
      Unsupported(message) => state.error(None, Unsupported(message))
      LimitExceeded(message) => state.error(None, LimitExceeded(message))
    }
  } else {
    state.coverage = false
    state.truncated = true
  }
  let ptrmap_checked = state.check_ptrmap(self)
  state.finish(self.page_count, ptrmap_checked)
}
