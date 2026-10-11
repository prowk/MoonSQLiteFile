///|
/// 选择字段的有限值预览；returned_bytes 为实际交付的原始字节数，truncated 表示未交付完整字段。
pub(all) struct FieldPreview {
  field : RecordField
  value : Value
  returned_bytes : Int
  truncated : Bool
} derive(Debug)

///|
pub extend FieldPreview with @debug.Debug::{to_repr}

///|
/// 记录头已验证；values 只包含所选物理列。未选字段及未读链不因此获得完整性结论。
pub(all) struct ProjectedRecord {
  rowid : Int64?
  page_number : Int
  cell_offset : Int
  header : RecordHeader
  values : Array[FieldPreview]
  record_complete : Bool
  overflow_chain_complete : Bool
  copied_bytes : UInt64
} derive(Debug)

///|
pub extend ProjectedRecord with @debug.Debug::{to_repr}

///|
/// BLOB 的一个原始字节区间；offset 从字段起点计数，more 表示后面仍有未返回字节。
pub(all) struct FieldChunk {
  field : RecordField
  offset : Int
  bytes : Bytes
  more : Bool
  overflow_chain_complete : Bool
  copied_bytes : UInt64
} derive(Debug)

///|
pub extend FieldChunk with @debug.Debug::{to_repr}

///|
/// 独立字段读取的供页协议；只请求完整页面，结束或 stop 后不再读取。
pub(all) enum FieldReadEvent {
  NeedFieldPage(Int)
  FieldRecordReady(ProjectedRecord)
  FieldChunkReady(FieldChunk)
  FieldReadFinished
} derive(Debug)

///|
pub extend FieldReadEvent with @debug.Debug::{to_repr}

///|
priv struct PayloadSliceReader {
  db : Database
  owner : Int
  initial : Bytes
  initial_next : Int
  size : Int
  occupied : Map[Int, PageUse]
  claimed : Map[Int, Bool]
  seen : Map[Int, Bool]
  max_copy : UInt64
  mut copied : UInt64
  mut segment : Bytes
  mut segment_start : Int
  mut next_page : Int
  mut pending : Int?
  mut start : Int
  mut length : Int
  mut count : Int
  mut buffer : @buffer.Buffer
  mut active : Bool
  mut chain_complete : Bool
}

///|
fn Database::payload_slice_reader(
  self : Database,
  bytes : Bytes,
  offset : Int,
  size : Int,
  table : Bool,
  owner : Int,
  occupied : Map[Int, PageUse],
  max_copy : UInt64,
) -> PayloadSliceReader raise SqliteError {
  let local_size = local_payload_size(size, self.header.usable_size, table)
  let extra = if local_size < size { 4 } else { 0 }
  if offset < 0 ||
    offset > self.header.usable_size ||
    local_size + extra > self.header.usable_size - offset {
    raise Invalid("cell payload 越过页面可用空间")
  }
  let initial = bytes[offset:offset + local_size].to_owned()
  let next = if extra == 0 {
    0
  } else {
    page_number(read_u32(bytes, offset + local_size))
  }
  {
    db: self,
    owner,
    initial,
    initial_next: next,
    size,
    occupied,
    claimed: Map([]),
    seen: Map([]),
    max_copy,
    copied: 0UL,
    segment: initial,
    segment_start: 0,
    next_page: next,
    pending: None,
    start: 0,
    length: 0,
    count: 0,
    buffer: @buffer.Buffer(),
    active: false,
    chain_complete: false,
  }
}

///|
fn PayloadSliceReader::begin(
  self : PayloadSliceReader,
  start : Int,
  length : Int,
) -> Unit raise SqliteError {
  if start < 0 || length < 0 || start > self.size || length > self.size - start {
    raise Invalid("字段读取区间越过 payload 边界")
  }
  if length.to_uint64() > self.max_copy - self.copied {
    raise LimitExceeded("字段复制字节预算不足")
  }
  // 在分配前计费；失败的请求不会退还预算。
  self.copied = self.copied + length.to_uint64()
  if start < self.segment_start {
    self.segment = self.initial
    self.segment_start = 0
    self.next_page = self.initial_next
    self.seen.clear()
  }
  self.start = start
  self.length = length
  self.count = 0
  self.buffer = @buffer.Buffer(size_hint=length)
  self.pending = None
  self.active = true
}

///|
fn PayloadSliceReader::advance(
  self : PayloadSliceReader,
) -> Int? raise SqliteError {
  if !self.active {
    raise Invalid("字段区间尚未开始")
  }
  if self.pending is Some(number) {
    return Some(number)
  }
  while self.count < self.length {
    let position = self.start + self.count
    let end = self.segment_start + self.segment.length()
    if position < end {
      let offset = position - self.segment_start
      let count = Int::min(end - position, self.length - self.count)
      self.buffer.write_bytes(self.segment[offset:offset + count])
      self.count = self.count + count
    } else {
      let number = self.next_page
      if number < 1 || number > self.db.page_count {
        raise Invalid("overflow 链被截断或页号越界")
      }
      if number == self.owner || self.seen.contains(number) {
        raise Invalid("overflow 链存在环或重复占用")
      }
      if self.occupied.contains(number) && !self.claimed.contains(number) {
        raise Invalid("overflow 页已经被其他记录或 B-tree 使用")
      }
      if !self.occupied.contains(number) &&
        self.occupied.length() >= self.db.limits.max_pages {
        raise LimitExceeded("字段读取总页数超过限制")
      }
      self.pending = Some(number)
      return Some(number)
    }
  }
  if self.start + self.length == self.size &&
    self.segment_start + self.segment.length() == self.size {
    if self.next_page != 0 {
      raise Invalid("overflow 链长于记录声明长度")
    }
    self.chain_complete = true
  }
  None
}

///|
fn PayloadSliceReader::provide(
  self : PayloadSliceReader,
  number : Int,
  bytes : Bytes,
) -> Unit raise SqliteError {
  if self.pending != Some(number) || bytes.length() != self.db.header.page_size {
    raise Invalid("字段游标未请求此页或供页长度错误")
  }
  let start = self.segment_start + self.segment.length()
  let count = Int::min(self.size - start, self.db.header.usable_size - 4)
  if count <= 0 {
    raise Invalid("overflow 链长于记录声明长度")
  }
  self.segment = bytes[4:4 + count].to_owned()
  self.segment_start = start
  self.next_page = page_number(read_u32(bytes, 0))
  self.seen[number] = true
  self.claimed[number] = true
  self.occupied[number] = Overflow
  self.pending = None
}

///|
fn PayloadSliceReader::bytes(
  self : PayloadSliceReader,
) -> Bytes raise SqliteError {
  if self.advance() is Some(_) {
    raise Invalid("字段区间尚未读取完成")
  }
  self.active = false
  self.buffer.to_bytes()
}

///|
fn prefix_text_bytes(
  data : Bytes,
  encoding : Int,
  truncated : Bool,
) -> Int raise SqliteError {
  if !truncated {
    return data.length()
  }
  if encoding == 1 {
    let mut position = 0
    while position < data.length() {
      let first = data[position].to_int()
      let width = if first < 128 {
        1
      } else if first >= 194 && first <= 223 {
        2
      } else if first >= 224 && first <= 239 {
        3
      } else if first >= 240 && first <= 244 {
        4
      } else {
        raise Invalid("记录文本不符合指定的 Unicode 编码")
      }
      if width > data.length() - position {
        // 已读到的续字节仍须合法，缺少的尾字节没有验证。
        for i = position + 1; i < data.length(); i = i + 1 {
          if data[i].to_int() < 128 || data[i].to_int() > 191 {
            raise Invalid("记录文本不符合指定的 Unicode 编码")
          }
        }
        if data.length() - position >= 2 {
          let second = data[position + 1].to_int()
          if (first == 224 && second < 160) ||
            (first == 237 && second > 159) ||
            (first == 240 && second < 144) ||
            (first == 244 && second > 143) {
            raise Invalid("记录文本不符合指定的 Unicode 编码")
          }
        }
        return position
      }
      position = position + width
    }
    data.length()
  } else {
    let mut count = data.length() / 2 * 2
    if count >= 2 {
      let unit = if encoding == 2 {
        data[count - 2].to_int() | (data[count - 1].to_int() << 8)
      } else {
        (data[count - 2].to_int() << 8) | data[count - 1].to_int()
      }
      if unit >= 0xd800 && unit <= 0xdbff {
        count = count - 2
      }
    }
    count
  }
}

///|
fn preview_field(
  field : RecordField,
  data : Bytes,
  encoding : Int,
) -> FieldPreview raise SqliteError {
  let serial = field.serial_type
  let mut returned = data.length()
  let value = match serial {
    0UL => Null
    1UL | 2UL | 3UL | 4UL | 5UL | 6UL =>
      Integer(record_integer(data, 0, field.byte_length))
    7UL => Real(record_integer(data, 0, 8).reinterpret_as_double())
    8UL => Integer(0L)
    9UL => Integer(1L)
    _ =>
      if serial % 2UL == 0UL {
        Blob(data)
      } else {
        returned = prefix_text_bytes(
          data,
          encoding,
          data.length() < field.byte_length,
        )
        Text(record_text(data.exact_view(start=0, end=returned), encoding))
      }
  }
  {
    field,
    value,
    returned_bytes: returned,
    truncated: returned < field.byte_length,
  }
}

///|
/// 单个 cell 的独立供页句柄；与扫描推进无关，stop 后失效。宿主数据库关闭时须停止该句柄。
pub struct FieldReadCursor {
  priv db : Database
  priv page : Int
  priv offset : Int
  priv selection : Array[Int]?
  priv selected_limit : Int
  priv field_bytes : Int
  priv header_bytes : Int
  priv max_fields : Int
  priv chunk : (Int, Int, Int)?
  priv occupied : Map[Int, PageUse]
  priv max_copy : UInt64
  priv mut reader : PayloadSliceReader?
  priv mut header : RecordHeader?
  priv mut rowid : Int64?
  priv mut stage : Int
  priv mut indices : Array[Int]
  priv mut index : Int
  priv values : Array[FieldPreview]
  priv mut supplied : Bytes?
  priv mut pending : Int?
  priv mut stopped : Bool
  priv mut stopped_progress : ScanProgress?
}

///|
/// 按物理列序号预览一个 cell；fields=None 读取前 max_selected_fields 列。文本限制以原始字节计并退回完整字符边界。
pub fn Database::field_cursor(
  self : Database,
  page : Int,
  cell_offset : Int,
  fields? : Array[Int]? = None,
  max_field_bytes? : Int = 256,
  max_header_bytes? : Int = 65536,
  max_fields? : Int = 2048,
  max_selected_fields? : Int = 128,
  max_total_copy_bytes? : UInt64 = 67108864UL,
) -> FieldReadCursor raise SqliteError {
  self.field_cursor_internal(
    page,
    cell_offset,
    fields,
    max_field_bytes,
    max_header_bytes,
    max_fields,
    max_selected_fields,
    max_total_copy_bytes,
    None,
    Map([]),
  )
}

///|
/// 读取 BLOB 的有界原始区间；每段最多 65536 字节。后部区间仍可能遍历前部 overflow 页，不能保证随机直达。
pub fn Database::blob_chunk_cursor(
  self : Database,
  page : Int,
  cell_offset : Int,
  field : Int,
  offset? : Int = 0,
  length? : Int = 65536,
  max_header_bytes? : Int = 65536,
  max_fields? : Int = 2048,
  max_total_copy_bytes? : UInt64 = 67108864UL,
) -> FieldReadCursor raise SqliteError {
  if field < 0 || offset < 0 || length < 0 || length > 65536 {
    raise LimitExceeded("BLOB 分块参数越界")
  }
  self.field_cursor_internal(
    page,
    cell_offset,
    Some([field]),
    65536,
    max_header_bytes,
    max_fields,
    1,
    max_total_copy_bytes,
    Some((field, offset, length)),
    Map([]),
  )
}

///|
fn Database::field_cursor_internal(
  self : Database,
  page : Int,
  offset : Int,
  selection : Array[Int]?,
  field_bytes : Int,
  header_bytes : Int,
  max_fields : Int,
  selected_limit : Int,
  max_copy : UInt64,
  chunk : (Int, Int, Int)?,
  occupied : Map[Int, PageUse],
) -> FieldReadCursor raise SqliteError {
  if page < 1 ||
    page > self.page_count ||
    offset < 0 ||
    offset >= self.header.usable_size {
    raise Invalid("记录位置越界")
  }
  if field_bytes < 0 ||
    field_bytes > 65536 ||
    header_bytes < 9 ||
    header_bytes > 65536 ||
    max_fields < 1 ||
    max_fields > 65536 ||
    selected_limit < 0 ||
    selected_limit > max_fields {
    raise LimitExceeded("字段预览预算越界")
  }
  if selection is Some(indices) {
    let seen : Map[Int, Bool] = Map([])
    for index in indices {
      if index < 0 || index >= max_fields || seen.contains(index) {
        raise Invalid("物理列序号越界或重复")
      }
      seen[index] = true
    }
    if indices.length() > selected_limit {
      raise LimitExceeded("所选字段数量超过限制")
    }
  }
  {
    db: self,
    page,
    offset,
    selection: selection.map(indices => indices.copy()),
    selected_limit,
    field_bytes,
    header_bytes,
    max_fields,
    chunk,
    occupied,
    max_copy,
    reader: None,
    header: None,
    rowid: None,
    stage: 0,
    indices: [],
    index: 0,
    values: [],
    supplied: None,
    pending: Some(page),
    stopped: false,
    stopped_progress: None,
  }
}

///|
/// 只接受 next 请求的页与完整 page_size 字节；不会直接调用源。
pub fn FieldReadCursor::provide_page(
  self : FieldReadCursor,
  page : Int,
  bytes : Bytes,
) -> Unit raise SqliteError {
  if self.stopped ||
    self.pending != Some(page) ||
    self.supplied is Some(_) ||
    bytes.length() != self.db.header.page_size {
    raise Invalid("字段游标未请求此页或供页错误")
  }
  self.supplied = Some(bytes)
}

///|
/// 释放页面与字段缓冲，使后续 next 返回结束；不关闭外部源。
pub fn FieldReadCursor::stop(self : FieldReadCursor) -> Unit {
  if self.stopped {
    return
  }
  self.stopped_progress = Some(self.progress())
  self.reader = None
  self.supplied = None
  self.pending = None
  self.header = None
  self.values.clear()
  self.stopped = true
}

///|
/// 返回已经计费的复制字节和已访问页数量；跳过内容的页面 I/O 另由宿主记录。
pub fn FieldReadCursor::progress(self : FieldReadCursor) -> ScanProgress {
  if self.stopped_progress is Some(progress) {
    return progress
  }
  {
    records_read: if self.stage == 4 {
      1
    } else {
      0
    },
    pages_read: self.occupied.length(),
    payload_bytes: self.reader.map(reader => reader.copied).unwrap_or(0UL),
  }
}

///|
fn FieldReadCursor::load(
  self : FieldReadCursor,
  bytes : Bytes,
) -> Unit raise SqliteError {
  let page = self.db.page_from_bytes(self.page, bytes)
  if page.kind == TableInterior || !page.cell_offsets.contains(self.offset) {
    raise Invalid("位置不是可读取的 record cell")
  }
  let position = self.offset + (if page.kind == IndexInterior { 4 } else { 0 })
  let (size, size_bytes) = page_varint(
    bytes,
    position,
    self.db.header.usable_size,
  )
  let size = bounded_int(size, "payload size")
  let table = page.kind == TableLeaf
  let (rowid, rowid_bytes) = if table {
    let (bits, count) = page_varint(
      bytes,
      position + size_bytes,
      self.db.header.usable_size,
    )
    (Some(bits.reinterpret_as_int64()), count)
  } else {
    (None, 0)
  }
  self.rowid = rowid
  self.occupied[self.page] = Btree
  let reader = self.db.payload_slice_reader(
    bytes,
    position + size_bytes + rowid_bytes,
    size,
    table,
    self.page,
    self.occupied,
    self.max_copy,
  )
  self.reader = Some(reader)
  reader.begin(0, Int::min(size, 9))
  self.stage = 1
}

///|
fn FieldReadCursor::start_field(
  self : FieldReadCursor,
) -> Unit raise SqliteError {
  let header = self.header.unwrap()
  let reader = self.reader.unwrap()
  let field = header.fields[self.indices[self.index]]
  if self.chunk is Some((_, offset, length)) {
    if field.serial_type < 12UL || field.serial_type % 2UL != 0UL {
      raise Invalid("分块读取只支持 BLOB 字段")
    }
    if offset > field.byte_length {
      raise Invalid("BLOB 偏移越界")
    }
    reader.begin(
      field.payload_offset + offset,
      Int::min(length, field.byte_length - offset),
    )
  } else {
    let count = if field.serial_type < 12UL {
      field.byte_length
    } else {
      Int::min(field.byte_length, self.field_bytes)
    }
    reader.begin(field.payload_offset, count)
  }
  self.stage = 3
}

///|
/// 推进至供页、有限预览或一个 BLOB 分块；错误后释放句柄，局部成功不保证未读字段或链尾有效。
pub fn FieldReadCursor::next(
  self : FieldReadCursor,
) -> FieldReadEvent raise SqliteError {
  if self.stopped {
    return FieldReadFinished
  }
  errdefer self.stop()
  if self.stage == 4 {
    return FieldReadFinished
  }
  if self.pending is Some(number) {
    if self.supplied is None {
      return NeedFieldPage(number)
    }
    let bytes = self.supplied.unwrap()
    self.supplied = None
    self.pending = None
    if self.stage == 0 {
      self.load(bytes)
    } else {
      self.reader.unwrap().provide(number, bytes)
    }
  }
  while true {
    let reader = self.reader.unwrap()
    if reader.advance() is Some(number) {
      self.pending = Some(number)
      return NeedFieldPage(number)
    }
    let data = reader.bytes()
    if self.stage == 1 {
      let (size, prefix) = decode_varint(data, 0)
      if size < prefix.to_uint64() || size > reader.size.to_uint64() {
        raise Invalid("记录头长度超出 payload 边界")
      }
      if size > self.header_bytes.to_uint64() {
        raise LimitExceeded("记录头超过字节预算")
      }
      reader.begin(0, size.to_int())
      self.stage = 2
    } else if self.stage == 2 {
      let header = parse_record_header(
        data,
        reader.size,
        max_fields=self.max_fields,
      )
      self.header = Some(header)
      self.indices = match self.selection {
        Some(indices) => indices.copy()
        None => {
          let count = Int::min(header.fields.length(), self.selected_limit)
          Array::makei(count, index => index)
        }
      }
      self.indices.sort_by((left, right) => left.compare(right))
      for index in self.indices {
        if index >= header.fields.length() {
          raise Invalid("物理列序号越界")
        }
      }
      if self.indices.is_empty() {
        self.stage = 4
        return FieldRecordReady({
          rowid: self.rowid,
          page_number: self.page,
          cell_offset: self.offset,
          header,
          values: [],
          record_complete: header.fields.is_empty() && reader.chain_complete,
          overflow_chain_complete: reader.chain_complete,
          copied_bytes: reader.copied,
        })
      }
      self.start_field()
    } else {
      let header = self.header.unwrap()
      let field = header.fields[self.indices[self.index]]
      if self.chunk is Some((_, offset, _)) {
        self.stage = 4
        return FieldChunkReady({
          field,
          offset,
          bytes: data,
          more: data.length() < field.byte_length - offset,
          overflow_chain_complete: reader.chain_complete,
          copied_bytes: reader.copied,
        })
      }
      self.values.push(preview_field(field, data, self.db.header.text_encoding))
      self.index = self.index + 1
      if self.index == self.indices.length() {
        self.stage = 4
        let complete = self.values.length() == header.fields.length() &&
          self.values.all(value => !value.truncated) &&
          reader.chain_complete
        return FieldRecordReady({
          rowid: self.rowid,
          page_number: self.page,
          cell_offset: self.offset,
          header,
          values: self.values.copy(),
          record_complete: complete,
          overflow_chain_complete: reader.chain_complete,
          copied_bytes: reader.copied,
        })
      }
      self.start_field()
    }
  } nobreak {
    abort("字段游标循环意外结束")
  }
}

///|
/// 同步驱动有限字段读取；只解码所选字段，不代表整条记录或全库完整性检查。
pub fn Database::preview_record(
  self : Database,
  page : Int,
  cell_offset : Int,
  fields? : Array[Int]? = None,
  max_field_bytes? : Int = 256,
) -> ProjectedRecord raise SqliteError {
  let cursor = self.field_cursor(page, cell_offset, fields~, max_field_bytes~)
  defer cursor.stop()
  while true {
    match cursor.next() {
      NeedFieldPage(page) => cursor.provide_page(page, self.read_page(page))
      FieldRecordReady(record) => return record
      _ => raise Invalid("字段游标未返回记录")
    }
  } nobreak {
    abort("字段读取意外结束")
  }
}
