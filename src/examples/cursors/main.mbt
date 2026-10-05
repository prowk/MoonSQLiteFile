///|
fn main {
  // 可运行的供页协议示例；异步宿主可在每次 NeedPage 事件中 await 范围读取。
  let bytes = b"SQLite format 3\x00\x02\x00\x01\x01\x00\x40\x20\x20" +
    Bytes::make(76, 0) +
    b"\x0d\x00\x00\x00\x00\x02\x00\x00" +
    Bytes::make(404, 0)
  try {
    let source = @sqlite.BytesSource::new(bytes)
    let cached = @sqlite.CachedSource::new(source, block_size=512, max_pages=1)
    let db = @sqlite.open_range_source(cached)
    let scan = db.scan_cursor(1)
    while true {
      match scan.next() {
        @sqlite.NeedPage(number) =>
          scan.provide_page(number, db.read_page(number))
        @sqlite.RecordReady(record) =>
          println("record page=\{record.page_number}")
        @sqlite.ScanFinished(summary) => {
          if summary.completion != @sqlite.Complete {
            abort("示例扫描未完成")
          }
          println("scan pages=\{summary.pages_read}")
          break
        }
      }
    }
    let inspection = db.inspection_cursor()
    while true {
      match inspection.next() {
        @sqlite.NeedInspectionPage(number) =>
          inspection.provide_page(number, db.read_page(number))
        @sqlite.InspectionProgress(_) => ()
        @sqlite.InspectionFinished(report) => {
          if report.inspection.status != @sqlite.Complete {
            abort("示例检查未完成")
          }
          println(
            "claimed pages=\{report.inspection.summarize().claimed_pages}",
          )
          break
        }
      }
    }
  } catch {
    @sqlite.Invalid(message)
    | @sqlite.Unsupported(message)
    | @sqlite.LimitExceeded(message) => abort(message)
  }
}
