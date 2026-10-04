///|
pub(all) enum WalChecksumOrder {
  LittleEndianChecksum
  BigEndianChecksum
} derive(Debug, Eq)

///|
pub extend WalChecksumOrder with @debug.Debug::{to_repr}

///|
pub extend WalChecksumOrder with Eq::{equal, not_equal}

///|
pub(all) struct WalHeader {
  checksum_order : WalChecksumOrder
  version : UInt
  page_size : Int
  checkpoint_sequence : UInt
  salt1 : UInt
  salt2 : UInt
  checksum1 : UInt
  checksum2 : UInt
} derive(Debug, Eq)

///|
pub extend WalHeader with @debug.Debug::{to_repr}

///|
pub extend WalHeader with Eq::{equal, not_equal}

///|
pub(all) struct WalFrame {
  index : Int
  byte_offset : Int
  page_number : UInt
  database_pages : UInt
  checksum1 : UInt
  checksum2 : UInt
} derive(Debug, Eq)

///|
pub extend WalFrame with @debug.Debug::{to_repr}

///|
pub extend WalFrame with Eq::{equal, not_equal}

///|
pub(all) struct WalCommit {
  frame_index : Int
  database_pages : UInt
} derive(Debug, Eq)

///|
pub extend WalCommit with @debug.Debug::{to_repr}

///|
pub extend WalCommit with Eq::{equal, not_equal}

///|
pub(all) enum WalStopReason {
  WalEndOfFile
  WalTruncatedFrame
  WalSaltMismatch
  WalChecksumMismatch
  WalInvalidFrame
  WalFrameLimit
} derive(Debug, Eq)

///|
pub extend WalStopReason with @debug.Debug::{to_repr}

///|
pub extend WalStopReason with Eq::{equal, not_equal}

///|
pub(all) struct WalInspection {
  header : WalHeader?
  frames : Array[WalFrame]
  commits : Array[WalCommit]
  committed_frames : Int
  database_pages : UInt?
  stop_reason : WalStopReason
  stop_offset : Int
  trailing_bytes : Int
} derive(Debug)

///|
pub extend WalInspection with @debug.Debug::{to_repr}

///|
fn wal_word(data : Bytes, offset : Int, order : WalChecksumOrder) -> UInt {
  let mut value = 0U
  for i = 0; i < 4; i = i + 1 {
    let index = match order {
      BigEndianChecksum => offset + i
      LittleEndianChecksum => offset + 3 - i
    }
    value = (value << 8) | data[index].to_uint()
  }
  value
}

///|
// 累计 checksum 使用模 2^32 无符号加法，存储字段始终为大端。
fn wal_checksum(
  data : Bytes,
  offset : Int,
  count : Int,
  order : WalChecksumOrder,
  initial : (UInt, UInt),
) -> (UInt, UInt) {
  let mut s0 = initial.0
  let mut s1 = initial.1
  for i = offset; i < offset + count; i = i + 8 {
    s0 = s0 + wal_word(data, i, order) + s1
    s1 = s1 + wal_word(data, i + 4, order) + s0
  }
  (s0, s1)
}

///|
/// 验证 WAL header；头部不完整、格式或 checksum 错误直接抛出错误。
pub fn parse_wal_header(data : Bytes) -> WalHeader raise SqliteError {
  require_range(data, 0, 32)
  let checksum_order = match read_u32(data, 0) {
    0x377f0682U => LittleEndianChecksum
    0x377f0683U => BigEndianChecksum
    _ => raise Invalid("WAL magic 不匹配")
  }
  let version = read_u32(data, 4)
  if version != 3007000U {
    raise Unsupported("未知 WAL 格式版本：\{version}")
  }
  let page_size = bounded_int(read_u32(data, 8).to_uint64(), "WAL page_size")
  if page_size < 512 || page_size > 65536 || (page_size & (page_size - 1)) != 0 {
    raise Invalid("无效 WAL page_size")
  }
  let checksum1 = read_u32(data, 24)
  let checksum2 = read_u32(data, 28)
  if wal_checksum(data, 0, 24, checksum_order, (0U, 0U)) !=
    (checksum1, checksum2) {
    raise Invalid("WAL header checksum 不匹配")
  }
  {
    checksum_order,
    version,
    page_size,
    checkpoint_sequence: read_u32(data, 12),
    salt1: read_u32(data, 16),
    salt2: read_u32(data, 20),
    checksum1,
    checksum2,
  }
}

///|
/// 只接受连续有效帧；遇到首个无效帧后不搜索更后面的提交标记。
pub fn inspect_wal(
  data : Bytes,
  max_frames? : Int = 100000,
) -> WalInspection raise SqliteError {
  if max_frames < 1 {
    raise Invalid("WAL 帧上限必须为正数")
  }
  if data.is_empty() {
    return {
      header: None,
      frames: [],
      commits: [],
      committed_frames: 0,
      database_pages: None,
      stop_reason: WalEndOfFile,
      stop_offset: 0,
      trailing_bytes: 0,
    }
  }
  let header = parse_wal_header(data)
  let frames : Array[WalFrame] = []
  let commits : Array[WalCommit] = []
  let mut offset = 32
  let mut checksum = (header.checksum1, header.checksum2)
  let mut committed_frames = 0
  let mut database_pages = None
  let mut stop_reason = WalEndOfFile
  let frame_size = 24 + header.page_size
  while offset < data.length() {
    if frames.length() == max_frames {
      stop_reason = WalFrameLimit
      break
    }
    if data.length() - offset < frame_size {
      stop_reason = WalTruncatedFrame
      break
    }
    if read_u32(data, offset + 8) != header.salt1 ||
      read_u32(data, offset + 12) != header.salt2 {
      stop_reason = WalSaltMismatch
      break
    }
    let page_number = read_u32(data, offset)
    let pages = read_u32(data, offset + 4)
    if page_number == 0U || page_number == 0xffffffffU || pages == 0xffffffffU {
      stop_reason = WalInvalidFrame
      break
    }
    let next = wal_checksum(data, offset, 8, header.checksum_order, checksum)
    let next = wal_checksum(
      data,
      offset + 24,
      header.page_size,
      header.checksum_order,
      next,
    )
    if next != (read_u32(data, offset + 16), read_u32(data, offset + 20)) {
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
    offset = offset + frame_size
  }
  {
    header: Some(header),
    frames,
    commits,
    committed_frames,
    database_pages,
    stop_reason,
    stop_offset: offset,
    trailing_bytes: data.length() - offset,
  }
}
