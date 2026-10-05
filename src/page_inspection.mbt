///|
/// 页内格式错误的分类；PageRead 表示输入或宿主读取失败。
pub(all) enum PageDiagnosticCode {
  PageRead
  PageTypeTag
  PageHeader
  CellPointer
  CellFormat
  Freeblock
  SpaceOverlap
  UntrackedSpace
  FragmentCount
  ChildPointer
} derive(Debug, Eq)

///|
pub extend PageDiagnosticCode with @debug.Debug::{to_repr}

///|
pub extend PageDiagnosticCode with Eq::{equal, not_equal}

///|
/// byte_offset 从页面起点计数；cell_index 从零计数。位置指向检查失败的字段或区间。
pub(all) struct PageDiagnostic {
  code : PageDiagnosticCode
  page_number : Int
  byte_offset : Int?
  cell_index : Int?
  error : SqliteError
} derive(Debug)

///|
pub extend PageDiagnostic with @debug.Debug::{to_repr}

///|
/// 空间项互不重叠，总和等于页面大小；payload 计数是 cell 声明值，不验证 overflow 链。
pub(all) struct PageStatistics {
  database_header_bytes : Int
  btree_header_bytes : Int
  pointer_bytes : Int
  unallocated_bytes : Int
  cell_bytes : Int
  freeblock_bytes : Int
  fragmented_bytes : Int
  reserved_bytes : Int
  payload_bytes : UInt64
  local_payload_bytes : UInt64
  max_payload_bytes : Int
  overflow_cells : Int
} derive(Debug)

///|
pub extend PageStatistics with @debug.Debug::{to_repr}

///|
/// 仅检查指定 B-tree 页的布局；失败时不返回可能误导的部分统计。
pub(all) struct PageInspection {
  status : InspectionStatus
  page : Page?
  statistics : PageStatistics?
  diagnostic : PageDiagnostic?
} derive(Debug)

///|
pub extend PageInspection with @debug.Debug::{to_repr}

///|
priv suberror PageValidationError {
  PageInvalid(PageDiagnostic)
}

///|
fn page_invalid(
  number : Int,
  code : PageDiagnosticCode,
  byte_offset : Int,
  message : String,
  cell_index? : Int? = None,
) -> PageValidationError {
  PageInvalid({
    code,
    page_number: number,
    byte_offset: Some(byte_offset),
    cell_index,
    error: Invalid(message),
  })
}

///|
fn page_u16(
  bytes : Bytes,
  number : Int,
  byte_offset : Int,
  code : PageDiagnosticCode,
  cell_index? : Int? = None,
) -> Int raise PageValidationError {
  read_u16(bytes, byte_offset) catch {
    error =>
      raise PageInvalid({
        code,
        page_number: number,
        byte_offset: Some(byte_offset),
        cell_index,
        error,
      })
  }
}

///|
pub fn Database::inspect_page(self : Database, number : Int) -> PageInspection {
  let bytes = self.read_page(number) catch {
    error =>
      // 无法读取完整页时不推断文件损坏，包括宿主返回的 Invalid。
      return {
        status: Incomplete,
        page: None,
        statistics: None,
        diagnostic: Some({
          code: PageRead,
          page_number: number,
          byte_offset: None,
          cell_index: None,
          error,
        }),
      }
  }
  try self.parse_btree_page(number, bytes) catch {
    PageInvalid(diagnostic) =>
      {
        status: match diagnostic.error {
          Invalid(_) => Failed
          Unsupported(_) | LimitExceeded(_) => Incomplete
        },
        page: None,
        statistics: None,
        diagnostic: Some(diagnostic),
      }
  } noraise {
    (page, statistics) =>
      {
        status: Complete,
        page: Some(page),
        statistics: Some(statistics),
        diagnostic: None,
      }
  }
}
