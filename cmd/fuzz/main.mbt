///|
// 宿主负责输入变更、运行隔离和重放；只有已知 SQLite 错误可作为正常结果。
extern "js" fn register_probe(
  probe : (Bytes, Int) -> String,
  wal_probe : (Bytes, Bytes) -> String,
) -> Unit =
  #| (probe, walProbe) => { globalThis.moonsqlitefileFuzz = probe; globalThis.moonsqlitefileWalFuzz = walProbe; }

///|
fn probe(bytes : Bytes, page_number : Int) -> String {
  try {
    let db = @sqlite.open_database(bytes, limits={
      max_rows: 256,
      max_payload_bytes: 65536,
      max_pages: 1024,
      max_depth: 32,
    })
    let details = db.inspect_database_details(
      max_total_payload_bytes=1048576UL,
      max_issues=16,
    )
    let report = details.inspection
    if report.records_decoded > 256 ||
      report.pages.length() > 1024 ||
      report.payload_bytes > 1048576UL ||
      report.issues.length() > 16 ||
      details.issues.length() != report.issues.length() {
      abort("全局检查越过预算或位置报告失去对应关系")
    }
    let summary = report.summarize()
    if summary.claimed_pages != report.pages.length() {
      abort("已认领页的汇总失去一致性")
    }
    let page = db.inspect_page(page_number)
    if page.status == @sqlite.Complete {
      let stats = page.statistics.unwrap()
      if stats.database_header_bytes +
        stats.btree_header_bytes +
        stats.pointer_bytes +
        stats.unallocated_bytes +
        stats.cell_bytes +
        stats.freeblock_bytes +
        stats.fragmented_bytes +
        stats.reserved_bytes !=
        db.header().page_size {
        abort("成功页面的空间分项没有覆盖一页")
      }
    }
    let tree = db.inspect_btree_details(
      page_number,
      limit=64,
      max_total_payload_bytes=65536UL,
    )
    if tree.inspection.records_decoded > 64 {
      abort("单树检查越过记录预算")
    }
    "accepted"
  } catch {
    @sqlite.Invalid(_) => "invalid"
    @sqlite.Unsupported(_) => "unsupported"
    @sqlite.LimitExceeded(_) => "limited"
  }
}

///|
fn main {
  register_probe(probe, wal_probe)
}

///|
fn wal_probe(base : Bytes, bytes : Bytes) -> String {
  try {
    let wal = @sqlite.inspect_wal(bytes, max_frames=256)
    if wal.frames.length() > 256 ||
      wal.commits.length() > wal.frames.length() ||
      wal.committed_frames > wal.frames.length() ||
      wal.stop_offset + wal.trailing_bytes != bytes.length() {
      abort("WAL 检查越过预算或有效前缀边界错误")
    }
    let db = @sqlite.open_wal_database(
      base,
      bytes,
      tail_policy=@sqlite.UseValidPrefix,
      max_frames=256,
      limits={
        max_rows: 256,
        max_payload_bytes: 65536,
        max_pages: 1024,
        max_depth: 32,
      },
    )
    let details = db.inspect_database_details(
      max_total_payload_bytes=1048576UL,
      max_issues=16,
    )
    let report = details.inspection
    if report.records_decoded > 256 ||
      report.pages.length() > 1024 ||
      report.payload_bytes > 1048576UL ||
      report.issues.length() > 16 ||
      details.issues.length() != report.issues.length() {
      abort("WAL 快照检查越过预算")
    }
    if report.summarize().claimed_pages != report.pages.length() {
      abort("WAL 快照归属汇总不一致")
    }
    ignore(db.inspect_page(1))
    ignore(
      db.inspect_btree_details(1, limit=64, max_total_payload_bytes=65536UL),
    )
    "accepted"
  } catch {
    @sqlite.Invalid(_) => "invalid"
    @sqlite.Unsupported(_) => "unsupported"
    @sqlite.LimitExceeded(_) => "limited"
  }
}
