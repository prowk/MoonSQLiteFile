///|
/// 宿主错误与文件格式错误分离；所有数据源须提供不可变的静态快照。
pub(all) suberror SourceError {
  HostFailure(String)
  ShortRead(String)
  RangeOutOfBounds(String)
}

///|
/// 长度和偏移为有符号 64 位；单次读取长度仍为 Int，必须精确返回请求长度。
pub(open) trait RangeSource {
  fn byte_length64(Self) -> Int64
  fn read_range64(Self, Int64, Int) -> Bytes raise SourceError
}

///|
pub struct PageSourceAdapter {
  source : &PageSource
}

///|
pub fn PageSourceAdapter::new(source : &PageSource) -> PageSourceAdapter {
  { source, }
}

///|
pub impl RangeSource for PageSourceAdapter with fn byte_length64(self) {
  self.source.byte_length().to_int64()
}

///|
pub impl RangeSource for PageSourceAdapter with fn read_range64(
  self,
  offset,
  count,
) {
  check_source_range(self.byte_length64(), offset, count)
  let data = self.source.read_range(offset.to_int(), count) catch {
    Invalid(message) | Unsupported(message) | LimitExceeded(message) =>
      raise HostFailure(message)
  }
  if data.length() != count {
    raise ShortRead(
      "旧 PageSource 短读：offset=\{offset}, expected=\{count}, actual=\{data.length()}",
    )
  }
  data
}

///|
pub impl RangeSource for BytesSource with fn byte_length64(self) {
  self.data.length().to_int64()
}

///|
pub impl RangeSource for BytesSource with fn read_range64(self, offset, count) {
  check_source_range(self.byte_length64(), offset, count)
  let start = offset.to_int()
  self.data[start:start + count].to_owned()
}

///|
fn check_source_range(
  size : Int64,
  offset : Int64,
  count : Int,
) -> Unit raise SourceError {
  if size < 0L ||
    offset < 0L ||
    count < 0 ||
    offset > size ||
    count.to_int64() > size - offset {
    raise RangeOutOfBounds(
      "范围读取越界：offset=\{offset}, count=\{count}, size=\{size}",
    )
  }
}

///|
fn range_read(
  source : &RangeSource,
  offset : Int64,
  count : Int,
) -> Bytes raise SourceError {
  check_source_range(source.byte_length64(), offset, count)
  let data = source.read_range64(offset, count)
  if data.length() != count {
    raise ShortRead(
      "范围读取短读：offset=\{offset}, expected=\{count}, actual=\{data.length()}",
    )
  }
  data
}

///|
fn range_sqlite_read(
  source : &RangeSource,
  offset : Int64,
  count : Int,
) -> Bytes raise SqliteError {
  range_read(source, offset, count) catch {
    HostFailure(message) => raise Unsupported("source/host_failure: \{message}")
    ShortRead(message) => raise Unsupported("source/short_read: \{message}")
    RangeOutOfBounds(message) =>
      raise Unsupported("source/range_out_of_bounds: \{message}")
  }
}

///|
priv enum DataSource {
  LegacySource(&PageSource)
  WideSource(&RangeSource)
}

///|
fn data_length(source : DataSource) -> Int64 {
  match source {
    LegacySource(source) => source.byte_length().to_int64()
    WideSource(source) => source.byte_length64()
  }
}

///|
fn data_read(
  source : DataSource,
  offset : Int64,
  count : Int,
) -> Bytes raise SqliteError {
  match source {
    LegacySource(source) => {
      if offset < 0L || offset > 2147483647L {
        raise LimitExceeded("旧 PageSource 偏移超出 Int 范围")
      }
      source_read(source, offset.to_int(), count)
    }
    WideSource(source) => range_sqlite_read(source, offset, count)
  }
}

///|
/// 64 位寻址；页号保持 Int，超过 2147483647 页显式拒绝，避免静默截断。
pub fn open_range_source(
  source : &RangeSource,
  limits? : Limits = Limits::default(),
  max_report_pages? : Int = 100000,
) -> Database raise SqliteError {
  open_data_source(WideSource(source), limits, None, max_report_pages~)
}

///|
pub(all) struct CacheStatistics {
  hits : Int64
  misses : Int64
  bytes_read : Int64
  resident_pages : Int
} derive(Debug)

///|
/// 按固定块缓存，FIFO 淘汰；缓存与扫描状态、归属报告、WAL 索引预算互相独立。
pub struct CachedSource {
  priv source : &RangeSource
  priv size : Int64
  priv block_size : Int
  priv capacity : Int
  priv blocks : Map[Int64, Bytes]
  priv slots : Array[Int64]
  priv mut next_slot : Int
  priv mut hits : Int64
  priv mut misses : Int64
  priv mut bytes_read : Int64
}

///|
pub fn CachedSource::new(
  source : &RangeSource,
  block_size? : Int = 4096,
  max_pages? : Int = 256,
) -> CachedSource raise SqliteError {
  if block_size < 1 ||
    block_size > 65536 ||
    max_pages < 1 ||
    max_pages > 1048576 {
    raise Invalid(
      "缓存块大小须在 1–65536、容量须在 1–1048576 之间",
    )
  }
  let size = source.byte_length64()
  if size < 0L {
    raise Invalid("数据源长度不能为负数")
  }
  {
    source,
    size,
    block_size,
    capacity: max_pages,
    blocks: Map([]),
    slots: [],
    next_slot: 0,
    hits: 0L,
    misses: 0L,
    bytes_read: 0L,
  }
}

///|
pub fn CachedSource::statistics(self : CachedSource) -> CacheStatistics {
  {
    hits: self.hits,
    misses: self.misses,
    bytes_read: self.bytes_read,
    resident_pages: self.blocks.length(),
  }
}

///|
pub impl RangeSource for CachedSource with fn byte_length64(self) {
  self.size
}

///|
pub impl RangeSource for CachedSource with fn read_range64(self, offset, count) {
  check_source_range(self.size, offset, count)
  let result : FixedArray[Byte] = FixedArray::make(count, 0)
  let mut copied = 0
  while copied < count {
    let position = offset + copied.to_int64()
    let key = position / self.block_size.to_int64()
    let start = key * self.block_size.to_int64()
    let data = match self.blocks.get(key) {
      Some(data) => {
        self.hits = self.hits + 1L
        data
      }
      None => {
        let size = Int64::min(self.block_size.to_int64(), self.size - start).to_int()
        let data = range_read(self.source, start, size)
        self.misses = self.misses + 1L
        self.bytes_read = self.bytes_read + size.to_int64()
        if self.slots.length() < self.capacity {
          self.slots.push(key)
        } else {
          self.blocks.remove(self.slots[self.next_slot])
          self.slots[self.next_slot] = key
          self.next_slot = (self.next_slot + 1) % self.capacity
        }
        self.blocks[key] = data
        data
      }
    }
    let in_block = (position - start).to_int()
    let length = Int::min(count - copied, data.length() - in_block)
    for i = 0; i < length; i = i + 1 {
      result[copied + i] = data[in_block + i]
    }
    copied = copied + length
  }
  Bytes::from_array(result)
}

///|
pub extend BytesSource with RangeSource::{byte_length64, read_range64}

///|
pub extend PageSourceAdapter with RangeSource::{byte_length64, read_range64}

///|
pub extend CachedSource with RangeSource::{byte_length64, read_range64}

///|
pub extend CacheStatistics with @debug.Debug::{to_repr}

///|
// 既有公开 Database.source 字段保持类型；64 位源无法表示的长度明确返回 -1。
priv struct LegacyRangeView {
  source : &RangeSource
}

///|
impl PageSource for LegacyRangeView with fn byte_length(self) {
  let size = self.source.byte_length64()
  if size < 0L || size > 2147483647L {
    -1
  } else {
    size.to_int()
  }
}

///|
impl PageSource for LegacyRangeView with fn read_range(self, offset, count) {
  if PageSource::byte_length(self) < 0 {
    raise LimitExceeded(
      "64 位数据源无法用旧 PageSource 表示，请使用 Database.source64",
    )
  }
  range_sqlite_read(self.source, offset.to_int64(), count)
}

///|
/// 返回用于完整读取的 64 位源；旧 source 字段保持 v0.5 的 Int 契约。
pub fn Database::source64(self : Database) -> &RangeSource {
  let result : &RangeSource = match self.data_source {
    LegacySource(source) => (PageSourceAdapter::new(source) : &RangeSource)
    WideSource(source) => source
  }
  result
}
