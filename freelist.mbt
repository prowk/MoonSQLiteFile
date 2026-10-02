///|
/// 返回 freelist 中的 trunk 与 leaf 页号，并校验计数与循环。
pub fn Database::freelist(self : Database) -> Array[Int] raise SqliteError {
  let result : Array[Int] = []
  let visited : Map[Int, Bool] = Map([])
  let mut next = page_number(self.header.freelist_trunk)
  while next != 0 {
    if next == 1 {
      raise Invalid("schema 页不能出现在 freelist")
    }
    if visited.contains(next) {
      raise Invalid("freelist 页重复或形成环")
    }
    if result.length() >= self.limits.max_pages {
      raise LimitExceeded("freelist 页数超过限制")
    }
    visited[next] = true
    result.push(next)
    let bytes = self.read_page(next)
    let count = page_number(read_u32(bytes, 4))
    if count > (self.header.usable_size - 8) / 4 {
      raise Invalid("freelist trunk 指针数组越界")
    }
    for i = 0; i < count; i = i + 1 {
      let leaf = page_number(read_u32(bytes, 8 + i * 4))
      if leaf <= 1 || leaf > self.page_count || visited.contains(leaf) {
        raise Invalid("freelist leaf 越界或重复")
      }
      if result.length() >= self.limits.max_pages {
        raise LimitExceeded("freelist 页数超过限制")
      }
      visited[leaf] = true
      result.push(leaf)
    }
    next = page_number(read_u32(bytes, 0))
  }
  if result.length().reinterpret_as_uint() != self.header.freelist_pages {
    raise Invalid("freelist 长度与数据库头不一致")
  }
  result
}
