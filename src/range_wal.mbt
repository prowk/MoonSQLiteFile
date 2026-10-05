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
  let cursor = WalCursor::new(source.byte_length64(), max_frames~)
  while true {
    match cursor.next() {
      NeedWalRange(offset, count) =>
        cursor.provide(offset, range_sqlite_read(source, offset, count))
      WalReady(report) => return report
    }
  } nobreak {
    abort("WAL 游标未结束")
  }
}
