///|
pub(all) struct Row {
  rowid : Int64
  values : Array[Value]
  page_number : Int
} derive(Debug)

///|
fn page_varint(bytes : Bytes, offset : Int, usable : Int) -> (UInt64, Int) raise SqliteError {
  if offset < 0 || offset >= usable { raise Invalid("cell varint 起点越界") }
  let result = decode_varint(bytes, offset)
  if result.1 > usable - offset { raise Invalid("cell varint 跨越页面保留空间") }
  result
}

///|
/// 以 rowid 顺序读取普通表；limit 为零时不读取任何行。
pub fn Database::read_table(self : Database, root : Int, limit? : Int = self.limits.max_rows) -> Array[Row] raise SqliteError {
  if limit < 0 || limit > self.limits.max_rows { raise LimitExceeded("行数请求超出资源限制") }
  let root_page = self.page(root)
  if root_page.kind == IndexLeaf || root_page.kind == IndexInterior {
    raise Unsupported("WITHOUT ROWID 表使用 index B-tree；请使用底层页面检查")
  }
  let rows : Array[Row] = []
  if limit == 0 { return rows }
  let stack : Array[(Int, Int)] = [(root, 1)]
  let visited : Map[Int, Bool] = Map([])
  let mut last_rowid : Int64? = None
  while !stack.is_empty() {
    let (number, depth) = stack.pop().unwrap()
    if depth > self.limits.max_depth { raise LimitExceeded("B-tree 深度超过限制") }
    if visited.contains(number) { raise Invalid("B-tree 子页重复或形成环") }
    if visited.length() >= self.limits.max_pages { raise LimitExceeded("B-tree 页数超过限制") }
    visited[number] = true
    let page = self.page(number)
    let bytes = self.read_page(number)
    let usable = self.header.usable_size
    match page.kind {
      TableInterior => {
        let children : Array[Int] = []
        let mut previous_key : Int64? = None
        for offset in page.cell_offsets {
          if offset > usable - 4 { raise Invalid("interior cell 子页指针越界") }
          let child = page_number(read_u32(bytes, offset))
          let (bits, _) = page_varint(bytes, offset + 4, usable)
          let key = bits.reinterpret_as_int64()
          if previous_key is Some(previous) && key <= previous { raise Invalid("interior rowid 未严格递增") }
          previous_key = Some(key)
          if child < 1 || child > self.page_count { raise Invalid("左子页越界") }
          children.push(child)
        }
        children.push(page.right_child.unwrap())
        // 栈按逆序加入子页，使输出遵循 B-tree 的键顺序。
        for i = children.length() - 1; i >= 0; i = i - 1 { stack.push((children[i], depth + 1)) }
      }
      TableLeaf => {
        for offset in page.cell_offsets {
          let (size_bits, size_bytes) = page_varint(bytes, offset, usable)
          let payload_size = bounded_int(size_bits, "payload size")
          let (rowid_bits, rowid_bytes) = page_varint(bytes, offset + size_bytes, usable)
          let rowid = rowid_bits.reinterpret_as_int64()
          if last_rowid is Some(previous) && rowid <= previous { raise Invalid("叶页 rowid 未严格递增") }
          last_rowid = Some(rowid)
          let payload = self.cell_payload(bytes, offset + size_bytes + rowid_bytes, payload_size, true)
          rows.push({ rowid, values: decode_record(payload, self.header.text_encoding), page_number: number })
          if rows.length() == limit {
            // 显式的小 limit 返回前缀；默认资源上限到达后若仍有数据则报告限制。
            if limit == self.limits.max_rows && (offset != page.cell_offsets[page.cell_count - 1] || !stack.is_empty()) {
              raise LimitExceeded("表行数超过资源限制；请指定更小的 limit 读取前缀")
            }
            return rows
          }
        }
      }
      _ => raise Invalid("普通表 B-tree 中出现 index 页")
    }
  }
  rows
}
