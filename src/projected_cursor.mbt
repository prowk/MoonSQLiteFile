///|
/// 有界字段投影扫描；完成只表示树遍历完成，记录和 overflow 链的完整性逐条标记。
pub(all) enum ProjectedScanEvent {
  NeedProjectedPage(Int)
  ProjectedRecordReady(ProjectedRecord)
  ProjectedScanFinished(ScanSummary)
} derive(Debug)

///|
pub extend ProjectedScanEvent with @debug.Debug::{to_repr}

///|
/// 复用 B-tree 遍历的字段投影游标；保留完整读取接口，不为短值预览分配完整 payload。
pub struct ProjectedCursor {
  priv cursor : BTreeCursor
  priv selection : Array[Int]?
  priv field_bytes : Int
  priv header_bytes : Int
  priv max_fields : Int
  priv selected_limit : Int
  priv max_copy : UInt64
  priv mut field : FieldReadCursor?
  priv mut records : Int
  priv mut copied : UInt64
  priv mut finished : ScanSummary?
}

///|
/// 按物理列序号扫描，复制预算含记录头与所选字段前缀，页预算仍限制跳过前部 overflow 的 I/O。
pub fn Database::projected_cursor(
  self : Database,
  root : Int,
  fields? : Array[Int]? = None,
  limit? : Int = self.limits.max_rows,
  max_field_bytes? : Int = 256,
  max_header_bytes? : Int = 65536,
  max_fields? : Int = 2048,
  max_selected_fields? : Int = 128,
  max_total_copy_bytes? : UInt64 = 67108864UL,
) -> ProjectedCursor raise SqliteError {
  let validation = self.field_cursor_internal(
    root,
    0,
    fields,
    max_field_bytes,
    max_header_bytes,
    max_fields,
    max_selected_fields,
    max_total_copy_bytes,
    None,
    Map([]),
  )
  validation.stop()
  let cursor = self.scan_cursor(root, limit~)
  cursor.locations_only = true
  {
    cursor,
    selection: fields.map(indices => indices.copy()),
    field_bytes: max_field_bytes,
    header_bytes: max_header_bytes,
    max_fields,
    selected_limit: max_selected_fields,
    max_copy: max_total_copy_bytes,
    field: None,
    records: 0,
    copied: 0UL,
    finished: None,
  }
}

///|
/// 已交付的投影记录、访问页面和已计费复制字节；不把未读取的大字段计为已复制。
pub fn ProjectedCursor::progress(self : ProjectedCursor) -> ScanProgress {
  if self.finished is Some(summary) {
    return {
      records_read: summary.records_read,
      pages_read: summary.pages_read,
      payload_bytes: summary.payload_bytes,
    }
  }
  let progress = self.cursor.progress()
  {
    records_read: self.records,
    pages_read: progress.pages_read,
    payload_bytes: self.copied +
    self.field.map(field => field.progress().payload_bytes).unwrap_or(0UL),
  }
}

///|
/// 停止并释放字段读取和树路径；返回已观察进度，不把停止当完整。
pub fn ProjectedCursor::stop(self : ProjectedCursor) -> ScanSummary {
  if self.finished is Some(summary) {
    return summary
  }
  let progress = self.progress()
  if self.field is Some(field) {
    field.stop()
  }
  self.field = None
  ignore(self.cursor.stop())
  let summary : ScanSummary = {
    records_read: progress.records_read,
    pages_read: progress.pages_read,
    payload_bytes: progress.payload_bytes,
    completion: VisitorStopped,
  }
  self.finished = Some(summary)
  summary
}

///|
/// 供应当前所请求的完整页面；不会执行宿主 I/O。
pub fn ProjectedCursor::provide_page(
  self : ProjectedCursor,
  page : Int,
  bytes : Bytes,
) -> Unit raise SqliteError {
  if self.finished is Some(_) {
    raise Invalid("投影游标已结束")
  }
  if self.field is Some(field) {
    field.provide_page(page, bytes)
  } else {
    self.cursor.provide_page(page, bytes)
  }
}

///|
/// 推进至记录、供页或结束；未读取字段不解码，失败后保留进度并终止。
pub fn ProjectedCursor::next(
  self : ProjectedCursor,
) -> ProjectedScanEvent raise SqliteError {
  if self.finished is Some(summary) {
    return ProjectedScanFinished(summary)
  }
  errdefer ignore(self.stop())
  while true {
    if self.field is Some(field) {
      match field.next() {
        NeedFieldPage(page) => return NeedProjectedPage(page)
        FieldRecordReady(record) => {
          self.copied = self.copied + record.copied_bytes
          self.records = self.records + 1
          field.stop()
          self.field = None
          self.cursor.location_bytes = None
          return ProjectedRecordReady(record)
        }
        _ => raise Invalid("投影字段游标没有返回记录")
      }
    } else {
      match self.cursor.next() {
        NeedPage(page) => return NeedProjectedPage(page)
        RecordReady(record) => {
          let field = self.cursor.db.field_cursor_internal(
            record.page_number,
            record.cell_offset,
            self.selection,
            self.field_bytes,
            self.header_bytes,
            self.max_fields,
            self.selected_limit,
            self.max_copy - self.copied,
            None,
            self.cursor.occupied,
          )
          field.provide_page(
            record.page_number,
            self.cursor.location_bytes.unwrap(),
          )
          self.field = Some(field)
        }
        ScanFinished(summary) => {
          let completed : ScanSummary = {
            records_read: self.records,
            pages_read: summary.pages_read,
            payload_bytes: self.copied,
            completion: summary.completion,
          }
          self.finished = Some(completed)
          return ProjectedScanFinished(completed)
        }
      }
    }
  } nobreak {
    abort("投影游标循环意外结束")
  }
}
