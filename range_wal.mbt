///|
pub(all) struct RangeWalFrame {
  index : Int
  byte_offset : Int64
  page_number : UInt
  database_pages : UInt
  checksum1 : UInt
  checksum2 : UInt
} derive(Debug, Eq)

///|
pub extend RangeWalFrame with @debug.Debug::{to_repr}

///|
pub extend RangeWalFrame with Eq::{equal, not_equal}

///|
pub(all) struct RangeWalCommit {
  frame_index : Int
  database_pages : UInt
} derive(Debug, Eq)

///|
pub extend RangeWalCommit with @debug.Debug::{to_repr}

///|
pub extend RangeWalCommit with Eq::{equal, not_equal}

///|
pub(all) struct RangeWalInspection {
  header : WalHeader?
  frames : Array[RangeWalFrame]
  commits : Array[RangeWalCommit]
  committed_frames : Int
  database_pages : UInt?
  stop_reason : WalStopReason
  stop_offset : Int64
  trailing_bytes : Int64
} derive(Debug)

///|
pub extend RangeWalInspection with @debug.Debug::{to_repr}

///|
/// 只接受连续有效帧；遇到首个无效帧后不搜索更后面的提交标记。
pub fn inspect_wal_source(
  source : &RangeSource,
  max_frames? : Int = 100000,
) -> RangeWalInspection raise SqliteError {
  if max_frames < 1 {
    raise Invalid("WAL 帧上限必须为正数")
  }
  let size = source.byte_length64()
  if size < 0L {
    raise Invalid("WAL 数据源长度不能为负数")
  }
  if size == 0L {
    return {
      header: None,
      frames: [],
      commits: [],
      committed_frames: 0,
      database_pages: None,
      stop_reason: WalEndOfFile,
      stop_offset: 0L,
      trailing_bytes: 0L,
    }
  }
  if size < 32L {
    raise Invalid("WAL header 不完整")
  }
  let header = parse_wal_header(range_sqlite_read(source, 0L, 32))
  let frames : Array[RangeWalFrame] = []
  let commits : Array[RangeWalCommit] = []
  let mut offset = 32L
  let mut checksum = (header.checksum1, header.checksum2)
  let mut committed_frames = 0
  let mut database_pages = None
  let mut stop_reason = WalEndOfFile
  let frame_size = 24 + header.page_size
  while offset < size {
    if frames.length() == max_frames {
      stop_reason = WalFrameLimit
      break
    }
    if size - offset < frame_size.to_int64() {
      stop_reason = WalTruncatedFrame
      break
    }
    let data = range_sqlite_read(source, offset, frame_size)
    if read_u32(data, 8) != header.salt1 || read_u32(data, 12) != header.salt2 {
      stop_reason = WalSaltMismatch
      break
    }
    let page_number = read_u32(data, 0)
    let pages = read_u32(data, 4)
    if page_number == 0U || page_number == 0xffffffffU || pages == 0xffffffffU {
      stop_reason = WalInvalidFrame
      break
    }
    let next = wal_checksum(data, 0, 8, header.checksum_order, checksum)
    let next = wal_checksum(
      data,
      24,
      header.page_size,
      header.checksum_order,
      next,
    )
    if next != (read_u32(data, 16), read_u32(data, 20)) {
      stop_reason = WalChecksumMismatch
      break
    }
    let index = frames.length() + 1
    frames.push({
      index,
      byte_offset: offset,
      page_number,
      database_pages: pages,
      checksum1: next.0,
      checksum2: next.1,
    })
    if pages != 0U {
      commits.push({ frame_index: index, database_pages: pages, })
      committed_frames = index
      database_pages = Some(pages)
    }
    checksum = next
    offset = offset + frame_size.to_int64()
  }
  {
    header: Some(header),
    frames,
    commits,
    committed_frames,
    database_pages,
    stop_reason,
    stop_offset: offset,
    trailing_bytes: size - offset,
  }
}
