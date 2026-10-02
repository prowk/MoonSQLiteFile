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
  // 空闲块必须按偏移递增且互不重叠；同时排除 cell 指针落入空闲块。
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
    for pointer in cell_offsets {
      if pointer >= freeblock && pointer < block_end {
        raise Invalid("cell 指针位于 freeblock 内")
      }
    }
    if next != 0 && next < block_end {
      raise Invalid("freeblock 链重叠或形成环")
    }
    freeblock = next
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
