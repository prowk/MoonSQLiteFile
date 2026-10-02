///|
fn local_payload_size(
  payload_size : Int,
  usable : Int,
  table_leaf : Bool,
) -> Int {
  let max_local = if table_leaf {
    usable - 35
  } else {
    (usable - 12) * 64 / 255 - 23
  }
  if payload_size <= max_local {
    return payload_size
  }
  let min_local = (usable - 12) * 32 / 255 - 23
  let candidate = min_local + (payload_size - min_local) % (usable - 4)
  if candidate <= max_local {
    candidate
  } else {
    min_local
  }
}

///|
fn Database::cell_payload_tracked(
  self : Database,
  page_bytes : Bytes,
  offset : Int,
  payload_size : Int,
  table_leaf : Bool,
  occupied : Map[Int, PageUse],
) -> Bytes raise SqliteError {
  if payload_size > self.limits.max_payload_bytes {
    raise LimitExceeded("记录 payload 超过资源限制")
  }
  let usable = self.header.usable_size
  let local_size = local_payload_size(payload_size, usable, table_leaf)
  let extra = if local_size < payload_size { 4 } else { 0 }
  if offset < 0 || offset > usable || local_size + extra > usable - offset {
    raise Invalid("cell payload 越过页面可用空间")
  }
  if extra == 0 {
    return page_bytes[offset:offset + local_size].to_owned()
  }
  let buffer = @buffer.Buffer(size_hint=payload_size)
  buffer.write_bytes(page_bytes[offset:offset + local_size])
  let mut remaining = payload_size - local_size
  let mut next = page_number(read_u32(page_bytes, offset + local_size))
  while remaining > 0 {
    if next == 0 {
      raise Invalid("overflow 链被截断")
    }
    if occupied.get(next) is Some(page_use) {
      raise Invalid(
        "overflow 页 \{next} 已用于 \{page_use_name(page_use)}，存在环或重复占用",
      )
    }
    if occupied.length() >= self.limits.max_pages {
      raise LimitExceeded("扫描总页数超过限制")
    }
    occupied[next] = Overflow
    let overflow = self.read_page(next)
    let count = if remaining < usable - 4 { remaining } else { usable - 4 }
    buffer.write_bytes(overflow[4:4 + count])
    remaining = remaining - count
    next = page_number(read_u32(overflow, 0))
  }
  if next != 0 {
    raise Invalid("overflow 链长于记录声明长度")
  }
  buffer.to_bytes()
}
