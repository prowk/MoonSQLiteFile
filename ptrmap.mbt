///|
pub(all) enum PtrmapType {
  RootPage
  FreePage
  FirstOverflow
  NextOverflow
  NonRootBtree
} derive(Debug, Eq)

///|
pub extend PtrmapType with @debug.Debug::{to_repr}

///|
pub extend PtrmapType with Eq::{equal, not_equal}

///|
pub(all) struct PtrmapEntry {
  page_number : Int
  map_page : Int
  kind : PtrmapType
  parent_page : Int
} derive(Debug, Eq)

///|
pub extend PtrmapEntry with @debug.Debug::{to_repr}

///|
pub extend PtrmapEntry with Eq::{equal, not_equal}

///|
fn ptrmap_page_number(number : Int, usable : Int, page_size : Int) -> Int {
  let step = usable / 5 + 1
  let map_page = (number - 2) / step * step + 2
  let lock_page = 1073741824 / page_size + 1
  if map_page == lock_page {
    map_page + 1
  } else {
    map_page
  }
}

///|
fn Database::visit_ptrmap(
  self : Database,
  visit : (PtrmapEntry) -> Bool raise SqliteError,
) -> Bool raise SqliteError {
  if self.header.largest_root_page == 0U {
    if self.header.incremental_vacuum {
      raise Invalid("未启用 auto-vacuum 却设置 incremental-vacuum")
    }
    return true
  }
  if self.header.largest_root_page.to_uint64() > self.page_count.to_uint64() {
    raise Invalid("largest root page 越界")
  }
  if self.page_count > self.limits.max_pages {
    raise LimitExceeded("Ptrmap 枚举超过页数预算")
  }
  let lock_page = 1073741824 / self.header.page_size + 1
  let mut cached_number = 0
  let mut cached = b""
  for number = 2; number <= self.page_count; number = number + 1 {
    if number == lock_page {
      continue
    }
    let map_page = ptrmap_page_number(
      number,
      self.header.usable_size,
      self.header.page_size,
    )
    if number == map_page {
      continue
    }
    if map_page != cached_number {
      cached = self.read_page(map_page)
      cached_number = map_page
    }
    let offset = (number - map_page - 1) * 5
    if offset < 0 || offset > self.header.usable_size - 5 {
      raise Invalid("Ptrmap 条目位置越界")
    }
    let kind = match cached[offset].to_int() {
      1 => RootPage
      2 => FreePage
      3 => FirstOverflow
      4 => NextOverflow
      5 => NonRootBtree
      _ => raise Invalid("页 \{number} 的 Ptrmap 类型无效")
    }
    let parent = page_number(read_u32(cached, offset + 1))
    let zero_parent = kind == RootPage || kind == FreePage
    if (zero_parent && parent != 0) ||
      (
        !zero_parent &&
        (parent < 1 || parent > self.page_count || parent == number)
      ) {
      raise Invalid("页 \{number} 的 Ptrmap 父页无效")
    }
    if !visit({ page_number: number, map_page, kind, parent_page: parent, }) {
      return false
    }
  }
  true
}

///|
/// 读取 auto-vacuum 反向指针；与真实页归属对照请使用 inspect_database。
pub fn Database::ptrmap_entries(
  self : Database,
) -> Array[PtrmapEntry] raise SqliteError {
  let entries : Array[PtrmapEntry] = []
  ignore(
    self.visit_ptrmap(entry => {
      entries.push(entry)
      true
    }),
  )
  entries
}

///|
fn OwnershipState::check_ptrmap(self : OwnershipState, db : Database) -> Bool {
  if db.header.largest_root_page == 0U {
    return true
  }
  if !self.coverage {
    return false
  }
  let largest = db.header.largest_root_page.reinterpret_as_int()
  let mut actual_largest = 1
  for number, owner in self.owners {
    if owner.kind == BtreeRoot {
      if number > actual_largest {
        actual_largest = number
      }
    } else if owner.kind != PointerMap &&
      owner.kind != LockByte &&
      number <= largest {
      self.failed = true
      self.issue(
        ScanError(
          None,
          Invalid(
            "auto-vacuum 的非根页出现在 largest root 之前：\{number}",
          ),
        ),
      )
    }
  }
  if actual_largest != largest {
    self.failed = true
    self.issue(
      ScanError(None, Invalid("largest root 与 schema 根页集合不一致")),
    )
  }
  let mut all_claimed = true
  let checked = db.visit_ptrmap(entry => {
    if self.issues.length() >= self.max_issues {
      self.truncated = true
      return false
    }
    if self.owners.get(entry.page_number) is Some(owner) {
      let expected = match owner.kind {
        BtreeRoot => RootPage
        BtreeChild => NonRootBtree
        OverflowFirst => FirstOverflow
        OverflowContinuation => NextOverflow
        FreelistTrunk | FreelistLeaf => FreePage
        PointerMap | LockByte => {
          all_claimed = false
          return true
        }
      }
      let parent = if expected == RootPage || expected == FreePage {
        0
      } else {
        owner.parent_page.unwrap()
      }
      if entry.kind != expected || entry.parent_page != parent {
        self.failed = true
        self.issue(PtrmapMismatch(entry, owner))
      }
    } else {
      // 尚无归属的页由最终覆盖检查报告，不根据 Ptrmap 推断真实归属。
      all_claimed = false
    }
    true
  }) catch {
    Invalid(message) => {
      self.failed = true
      self.issue(ScanError(None, Invalid(message)))
      false
    }
    Unsupported(message) => {
      self.issue(ScanError(None, Unsupported(message)))
      false
    }
    LimitExceeded(message) => {
      self.issue(ScanError(None, LimitExceeded(message)))
      false
    }
  }
  checked && all_claimed
}
