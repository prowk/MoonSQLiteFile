///|
pub(all) enum PageType {
  TableLeaf
  TableInterior
  IndexLeaf
  IndexInterior
} derive(Debug, Eq)

///|
pub extend PageType with @debug.Debug::{to_repr}

///|
pub extend PageType with Eq::{equal, not_equal}

///|
pub(all) struct Page {
  number : Int
  kind : PageType
  first_freeblock : Int
  cell_count : Int
  content_start : Int
  fragmented_bytes : Int
  right_child : Int?
  cell_offsets : Array[Int]
} derive(Debug)

///|
pub extend Page with @debug.Debug::{to_repr}

///|
pub fn Database::page(self : Database, number : Int) -> Page raise SqliteError {
  self.page_from_bytes(number, self.read_page(number))
}

///|
fn Database::page_from_bytes(
  self : Database,
  number : Int,
  bytes : Bytes,
) -> Page raise SqliteError {
  let offset = if number == 1 { 100 } else { 0 }
  let kind = match bytes[offset].to_int() {
    13 => TableLeaf
    5 => TableInterior
    10 => IndexLeaf
    2 => IndexInterior
    other => raise Invalid("页 \{number} 不是 B-tree 页：type=\{other}")
  }
  let interior = kind == TableInterior || kind == IndexInterior
  let header_size = if interior { 12 } else { 8 }
  let cell_count = read_u16(bytes, offset + 3)
  let pointers_end = offset + header_size + cell_count * 2
  let usable = self.header.usable_size
  if pointers_end > usable {
    raise Invalid("cell pointer array 越界")
  }
  let raw_start = read_u16(bytes, offset + 5)
  let content_start = if raw_start == 0 { 65536 } else { raw_start }
  if content_start < pointers_end || content_start > usable {
    raise Invalid("无效 cell content 起点")
  }
  let fragmented_bytes = bytes[offset + 7].to_int()
  if fragmented_bytes > 60 {
    raise Invalid("碎片字节数超过 60")
  }
  let first_freeblock = read_u16(bytes, offset + 1)
  if first_freeblock != 0 &&
    (first_freeblock < content_start || first_freeblock > usable - 4) {
    raise Invalid("freeblock 指针越界")
  }
  let seen : Map[Int, Bool] = Map([])
  let cell_offsets : Array[Int] = []
  for i = 0; i < cell_count; i = i + 1 {
    let pointer = read_u16(bytes, offset + header_size + i * 2)
    if pointer < content_start || pointer >= usable || seen.contains(pointer) {
      raise Invalid("cell 指针越界或重复")
    }
    seen[pointer] = true
    cell_offsets.push(pointer)
  }
  // 按完整字节区间记录 cell 与 freeblock，避免仅检查起点而遗漏内容重叠。
  let spans : Array[(Int, Int)] = []
  for pointer in cell_offsets {
    spans.push((pointer, page_cell_end(bytes, pointer, kind, usable)))
  }
  // 空闲块链仍须按偏移递增；空间覆盖统一在排序后检查。
  let mut freeblock = first_freeblock
  while freeblock != 0 {
    if freeblock < content_start || freeblock > usable - 4 {
      raise Invalid("freeblock 链指针越界")
    }
    let next = read_u16(bytes, freeblock)
    let size = read_u16(bytes, freeblock + 2)
    if size < 4 || size > usable - freeblock {
      raise Invalid("freeblock 长度无效")
    }
    let block_end = freeblock + size
    spans.push((freeblock, block_end))
    if next != 0 && next < block_end + 4 {
      raise Invalid("freeblock 链重叠、间距不足或形成环")
    }
    freeblock = next
  }
  if !interior &&
    cell_count == 0 &&
    (content_start != usable || first_freeblock != 0 || fragmented_bytes != 0) {
    raise Invalid("页 \{number} 的空叶页不能包含 cell content 空间")
  }
  spans.sort_by((left, right) => left.0.compare(right.0))
  let mut cursor = content_start
  let mut fragments = 0
  for (start, end) in spans {
    if start < cursor {
      raise Invalid(
        "页 \{number} 的 cell/freeblock 区间重叠：offset=\{start}",
      )
    }
    let gap = start - cursor
    if gap >= 4 {
      raise Invalid(
        "页 \{number} 的空闲区间未登记为 freeblock：offset=\{cursor}",
      )
    }
    fragments = fragments + gap
    cursor = end
  }
  let tail = usable - cursor
  if tail >= 4 {
    raise Invalid(
      "页 \{number} 的尾部空闲区间未登记为 freeblock：offset=\{cursor}",
    )
  }
  fragments = fragments + tail
  if fragments != fragmented_bytes {
    raise Invalid(
      "页 \{number} 的碎片计数不一致：declared=\{fragmented_bytes}, actual=\{fragments}",
    )
  }
  let right_child = if interior {
    let child = page_number(read_u32(bytes, offset + 8))
    if child < 1 || child > self.page_count {
      raise Invalid("右子页越界")
    }
    Some(child)
  } else {
    None
  }
  {
    number,
    kind,
    first_freeblock,
    cell_count,
    content_start,
    fragmented_bytes,
    right_child,
    cell_offsets,
  }
}

///|
fn page_cell_end(
  bytes : Bytes,
  offset : Int,
  kind : PageType,
  usable : Int,
) -> Int raise SqliteError {
  let interior = kind == TableInterior || kind == IndexInterior
  if interior && offset > usable - 4 {
    raise Invalid("interior cell 子页指针越过页面可用空间")
  }
  let mut cursor = offset + (if interior { 4 } else { 0 })
  let (value, width) = page_varint(bytes, cursor, usable)
  cursor = cursor + width
  if kind != TableInterior {
    let payload_size = bounded_int(value, "payload size")
    if kind == TableLeaf {
      let (_, rowid_width) = page_varint(bytes, cursor, usable)
      cursor = cursor + rowid_width
    }
    let local_size = local_payload_size(payload_size, usable, kind == TableLeaf)
    let extra = if local_size < payload_size { 4 } else { 0 }
    if local_size + extra > usable - cursor {
      raise Invalid("cell payload 越过页面可用空间：offset=\{offset}")
    }
    cursor = cursor + local_size + extra
  }
  // SQLite 的小 cell 至少占四字节；填充字节同样不能被其他 cell 或空闲块占用。
  let size = if cursor - offset < 4 { 4 } else { cursor - offset }
  if size > usable - offset {
    raise Invalid(
      "cell 最小空间越过页面可用边界：offset=\{offset}",
    )
  }
  offset + size
}
