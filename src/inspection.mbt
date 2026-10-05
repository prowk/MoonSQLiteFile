///|
/// 仅描述指定根页的扫描结果，不代表整个数据库的完整性结论。
pub(all) enum InspectionStatus {
  Complete
  Incomplete
  Failed
} derive(Debug, Eq)

///|
pub extend InspectionStatus with @debug.Debug::{to_repr}

///|
pub extend InspectionStatus with Eq::{equal, not_equal}

///|
/// 不保存记录数组；发生错误时仍保留此前成功解码的记录数。
pub(all) struct BTreeInspection {
  root_page : Int
  status : InspectionStatus
  records_decoded : Int
  summary : ScanSummary?
  error : SqliteError?
} derive(Debug)

///|
pub extend BTreeInspection with @debug.Debug::{to_repr}

///|
fn inspection_failure(
  root : Int,
  records_decoded : Int,
  error : SqliteError,
) -> BTreeInspection {
  let status = match error {
    Invalid(_) => Failed
    Unsupported(_) | LimitExceeded(_) => Incomplete
  }
  {
    root_page: root,
    status,
    records_decoded,
    summary: None,
    error: Some(error),
  }
}

///|
/// 检查单棵 B-tree，保留完成状态或原始错误；资源不足不判为格式损坏。
pub fn Database::inspect_btree(
  self : Database,
  root : Int,
  limit? : Int = self.limits.max_rows,
  max_total_payload_bytes? : UInt64 = 67108864UL,
) -> BTreeInspection {
  let mut records_decoded = 0
  try
    self.scan_btree(
      root,
      _ => {
        records_decoded = records_decoded + 1
        true
      },
      limit~,
      max_total_payload_bytes~,
    )
  catch {
    Invalid(message) =>
      inspection_failure(root, records_decoded, Invalid(message))
    Unsupported(message) =>
      inspection_failure(root, records_decoded, Unsupported(message))
    LimitExceeded(message) =>
      inspection_failure(root, records_decoded, LimitExceeded(message))
  } noraise {
    summary => {
      let status = if summary.completion == Complete {
        InspectionStatus::Complete
      } else {
        InspectionStatus::Incomplete
      }
      {
        root_page: root,
        status,
        records_decoded,
        summary: Some(summary),
        error: None,
      }
    }
  }
}
