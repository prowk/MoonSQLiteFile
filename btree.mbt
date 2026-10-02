///|
/// 原始存储记录；index B-tree 没有独立 rowid，字段按磁盘顺序保留。
pub(all) struct BTreeRecord {
  rowid : Int64?
  values : Array[Value]
  page_number : Int
  cell_offset : Int
} derive(Debug)

///|
pub extend BTreeRecord with @debug.Debug::{to_repr}

///|
pub(all) enum ScanCompletion {
  Complete
  RecordLimit
  VisitorStopped
} derive(Debug, Eq)

///|
pub extend ScanCompletion with @debug.Debug::{to_repr}

///|
pub extend ScanCompletion with Eq::{equal, not_equal}

///|
pub(all) struct ScanSummary {
  records_read : Int
  pages_read : Int
  payload_bytes : UInt64
  completion : ScanCompletion
} derive(Debug)

///|
pub extend ScanSummary with @debug.Debug::{to_repr}

///|
priv enum PageUse {
  Btree
  Overflow
}

///|
priv struct ScanObserver {
  claim : (Int, PageKind, Int?) -> Unit raise SqliteError
  charge_payload : (UInt64) -> Unit
}

///|
fn quiet_observer() -> ScanObserver {
  { claim: (_, _, _) => (), charge_payload: _ => (), }
}

///|
fn page_use_name(page_use : PageUse) -> String {
  match page_use {
    Btree => "B-tree"
    Overflow => "overflow"
  }
}

///|
priv struct WalkFrame {
  page : Page
  bytes : Bytes
  depth : Int
  lower : Int64?
  upper : Int64?
  mut cursor : Int
  mut previous_key : Int64?
  mut emit_pending : Bool
  mut right_visited : Bool
}

///|
fn Database::walk_frame(
  self : Database,
  number : Int,
  depth : Int,
  lower : Int64?,
  upper : Int64?,
  table : Bool,
  occupied : Map[Int, PageUse],
  parent : Int?,
  observer : ScanObserver,
) -> WalkFrame raise SqliteError {
  if depth > self.limits.max_depth {
    raise LimitExceeded("B-tree 深度超过限制")
  }
  if occupied.get(number) is Some(page_use) {
    raise Invalid(
      "页 \{number} 已用于 \{page_use_name(page_use)}，不能重复用于 B-tree",
    )
  }
  if occupied.length() >= self.limits.max_pages {
    raise LimitExceeded("扫描总页数超过限制")
  }
  let bytes = self.read_page(number)
  (observer.claim)(
    number,
    if parent is None {
      BtreeRoot
    } else {
      BtreeChild
    },
    parent,
  )
  occupied[number] = Btree
  let page = self.page_from_bytes(number, bytes)
  let page_is_table = page.kind == TableLeaf || page.kind == TableInterior
  if page_is_table != table {
    raise Invalid("B-tree 中混入不同类型的页面")
  }
  {
    page,
    bytes,
    depth,
    lower,
    upper,
    cursor: 0,
    previous_key: lower,
    emit_pending: false,
    right_visited: false,
  }
}

///|
/// 按 B-tree 顺序逐条回调，返回 false 可停止；无需在库中保存所有结果。
pub fn Database::scan_btree(
  self : Database,
  root : Int,
  visit : (BTreeRecord) -> Bool raise SqliteError,
  limit? : Int = self.limits.max_rows,
  max_total_payload_bytes? : UInt64 = 67108864UL,
) -> ScanSummary raise SqliteError {
  self.scan_btree_observed(
    root,
    visit,
    quiet_observer(),
    limit~,
    max_total_payload_bytes~,
  )
}

///|
fn Database::scan_btree_observed(
  self : Database,
  root : Int,
  visit : (BTreeRecord) -> Bool raise SqliteError,
  observer : ScanObserver,
  limit~ : Int,
  max_total_payload_bytes~ : UInt64,
) -> ScanSummary raise SqliteError {
  if limit < 0 || limit > self.limits.max_rows {
    raise LimitExceeded("记录数请求超出资源限制")
  }
  let root_page = self.page(root)
  let table = root_page.kind == TableLeaf || root_page.kind == TableInterior
  let occupied : Map[Int, PageUse] = Map([])
  let stack = [
    self.walk_frame(root, 1, None, None, table, occupied, None, observer),
  ]
  let mut records_read = 0
  let mut payload_bytes = 0UL
  let mut last_rowid : Int64? = None
  let mut leaf_depth : Int? = None
  while !stack.is_empty() {
    let frame = stack[stack.length() - 1]
    let page = frame.page
    let bytes = frame.bytes
    let usable = self.header.usable_size
    let interior = page.kind == TableInterior || page.kind == IndexInterior
    if frame.cursor == page.cell_count {
      if interior && !frame.right_visited {
        frame.right_visited = true
        stack.push(
          self.walk_frame(
            page.right_child.unwrap(),
            frame.depth + 1,
            frame.previous_key,
            frame.upper,
            table,
            occupied,
            Some(page.number),
            observer,
          ),
        )
      } else {
        let _ = stack.pop()
      }
      continue
    }
    let offset = page.cell_offsets[frame.cursor]
    if interior && !frame.emit_pending {
      if offset > usable - 4 {
        raise Invalid("interior cell 子页指针越界")
      }
      let child = page_number(read_u32(bytes, offset))
      let mut upper = frame.upper
      if table {
        let (bits, _) = page_varint(bytes, offset + 4, usable)
        let key = bits.reinterpret_as_int64()
        if frame.previous_key is Some(previous) && key <= previous {
          raise Invalid("interior rowid 未严格递增")
        }
        if frame.upper is Some(bound) && key > bound {
          raise Invalid("interior rowid 越过父页键范围")
        }
        upper = Some(key)
      }
      let lower = frame.previous_key
      if table {
        frame.previous_key = upper
        frame.cursor = frame.cursor + 1
      } else {
        // 索引内部 cell 本身就是记录，必须先访问左子树再返回该记录。
        frame.emit_pending = true
      }
      stack.push(
        self.walk_frame(
          child,
          frame.depth + 1,
          lower,
          upper,
          table,
          occupied,
          Some(page.number),
          observer,
        ),
      )
      continue
    }
    if !interior {
      if leaf_depth is Some(expected) && expected != frame.depth {
        raise Invalid("B-tree 叶页深度不一致")
      }
      leaf_depth = Some(frame.depth)
    }
    if records_read == limit {
      return {
        records_read,
        pages_read: occupied.length(),
        payload_bytes,
        completion: RecordLimit,
      }
    }
    let payload_offset = if page.kind == IndexInterior {
      offset + 4
    } else {
      offset
    }
    let (size_bits, size_bytes) = page_varint(bytes, payload_offset, usable)
    let payload_size = bounded_int(size_bits, "payload size")
    if payload_size.to_uint64() > max_total_payload_bytes - payload_bytes {
      raise LimitExceeded("扫描累计 payload 超过字节预算")
    }
    // 数据库级预算在分配和解码前计入本次请求，失败也不退还预算。
    (observer.charge_payload)(payload_size.to_uint64())
    let (rowid, rowid_bytes) = if table {
      let (bits, size) = page_varint(bytes, payload_offset + size_bytes, usable)
      let rowid = bits.reinterpret_as_int64()
      if frame.lower is Some(bound) && rowid <= bound {
        raise Invalid("叶页 rowid 低于父页键范围")
      }
      if frame.upper is Some(bound) && rowid > bound {
        raise Invalid("叶页 rowid 高于父页键范围")
      }
      if last_rowid is Some(previous) && rowid <= previous {
        raise Invalid("叶页 rowid 未严格递增")
      }
      last_rowid = Some(rowid)
      (Some(rowid), size)
    } else {
      (None, 0)
    }
    let payload = self.cell_payload_tracked(
      bytes,
      payload_offset + size_bytes + rowid_bytes,
      payload_size,
      table,
      occupied,
      owner_page=page.number,
      observer~,
    )
    let record = {
      rowid,
      values: decode_record(payload, self.header.text_encoding),
      page_number: page.number,
      cell_offset: offset,
    }
    payload_bytes = payload_bytes + payload_size.to_uint64()
    records_read = records_read + 1
    frame.cursor = frame.cursor + 1
    frame.emit_pending = false
    if !visit(record) {
      return {
        records_read,
        pages_read: occupied.length(),
        payload_bytes,
        completion: VisitorStopped,
      }
    }
  }
  {
    records_read,
    pages_read: occupied.length(),
    payload_bytes,
    completion: Complete,
  }
}

///|
pub fn Database::read_btree(
  self : Database,
  root : Int,
  limit? : Int = self.limits.max_rows,
  max_total_payload_bytes? : UInt64 = 67108864UL,
) -> Array[BTreeRecord] raise SqliteError {
  let records : Array[BTreeRecord] = []
  let summary = self.scan_btree(
    root,
    record => {
      records.push(record)
      true
    },
    limit~,
    max_total_payload_bytes~,
  )
  if limit == self.limits.max_rows && summary.completion != Complete {
    raise LimitExceeded(
      "记录数超过资源限制；请指定更小的 limit 读取前缀",
    )
  }
  records
}

///|
pub fn Database::read_index(
  self : Database,
  root : Int,
  limit? : Int = self.limits.max_rows,
) -> Array[BTreeRecord] raise SqliteError {
  let page = self.page(root)
  if page.kind != IndexLeaf && page.kind != IndexInterior {
    raise Invalid("根页不是 index B-tree")
  }
  self.read_btree(root, limit~)
}
