///|
// 宿主负责输入变更、运行隔离和重放；只有已知 SQLite 错误可作为正常结果。
extern "js" fn register_probe(
  probe : (Bytes, Int) -> String,
  wal_probe : (Bytes, Bytes) -> String,
) -> Unit =
  #| (probe, walProbe) => { globalThis.moonsqlitefileFuzz = probe; globalThis.moonsqlitefileWalFuzz = walProbe; }

///|
fn legacy_probe(bytes : Bytes, page_number : Int) -> String {
  try {
    let db = @sqlite.open_database(bytes, limits={
      max_rows: 256,
      max_payload_bytes: 65536,
      max_pages: 1024,
      max_depth: 32,
    })
    check_database(db, page_number)
  } catch {
    @sqlite.Invalid(_) => "invalid"
    @sqlite.Unsupported(_) => "unsupported"
    @sqlite.LimitExceeded(_) => "limited"
  }
}

///|
fn check_database(db : @sqlite.Database, page_number : Int) -> String {
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
  @debug.to_string(details) + @debug.to_string(page) + @debug.to_string(tree)
}

///|
fn fuzz_limits() -> @sqlite.Limits {
  { max_rows: 256, max_payload_bytes: 65536, max_pages: 1024, max_depth: 32, }
}

///|
fn range_probe(
  bytes : Bytes,
  page_number : Int,
  adapter : Bool,
  cached : Bool,
) -> String {
  try {
    let raw : &@sqlite.RangeSource = if adapter {
      (
        @sqlite.PageSourceAdapter::new(@sqlite.BytesSource::new(bytes)) :
        &@sqlite.RangeSource)
    } else {
      @sqlite.BytesSource::new(bytes)
    }
    let source : &@sqlite.RangeSource = if cached {
      (
        @sqlite.CachedSource::new(raw, block_size=512, max_pages=2) :
        &@sqlite.RangeSource)
    } else {
      raw
    }
    let db = @sqlite.open_range_source(
      source,
      limits=fuzz_limits(),
      max_report_pages=1024,
    )
    check_database(db, page_number)
  } catch {
    @sqlite.Invalid(_) => "invalid"
    @sqlite.Unsupported(_) => "unsupported"
    @sqlite.LimitExceeded(_) => "limited"
  }
}

///|
fn probe(bytes : Bytes, page_number : Int) -> String {
  let legacy = legacy_probe(bytes, page_number)
  // 不足 100 字节时，旧入口报告 Invalid；范围入口报告可识别的源越界。
  let expected = if bytes.length() < 100 {
    let actual = range_probe(bytes, page_number, false, false)
    if legacy != "invalid" || actual != "unsupported" {
      abort("短文件初始化分类不符合入口契约")
    }
    actual
  } else {
    legacy
  }
  for adapter in [false, true] {
    for cached in [false, true] {
      let actual = range_probe(bytes, page_number, adapter, cached)
      if actual != expected {
        abort(
          "普通数据库范围源、适配器或缓存与旧入口差分不一致",
        )
      }
    }
  }
  fault_probe(bytes)
  report_fault_probe(bytes)
  if expected == "invalid" || expected == "unsupported" || expected == "limited" {
    expected
  } else {
    "accepted"
  }
}

///|
fn main {
  register_probe(probe, wal_probe)
}

///|
fn legacy_wal_probe(base : Bytes, bytes : Bytes) -> String {
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
    check_database(db, 1)
  } catch {
    @sqlite.Invalid(_) => "invalid"
    @sqlite.Unsupported(_) => "unsupported"
    @sqlite.LimitExceeded(_) => "limited"
  }
}

///|
fn range_wal_probe(
  base : Bytes,
  bytes : Bytes,
  adapter : Bool,
  cached : Bool,
) -> String {
  try {
    let raw_base : &@sqlite.RangeSource = if adapter {
      (
        @sqlite.PageSourceAdapter::new(@sqlite.BytesSource::new(base)) :
        &@sqlite.RangeSource)
    } else {
      @sqlite.BytesSource::new(base)
    }
    let raw_wal : &@sqlite.RangeSource = if adapter {
      (
        @sqlite.PageSourceAdapter::new(@sqlite.BytesSource::new(bytes)) :
        &@sqlite.RangeSource)
    } else {
      @sqlite.BytesSource::new(bytes)
    }
    let source_base : &@sqlite.RangeSource = if cached {
      (
        @sqlite.CachedSource::new(raw_base, block_size=512, max_pages=2) :
        &@sqlite.RangeSource)
    } else {
      raw_base
    }
    let source_wal : &@sqlite.RangeSource = if cached {
      (
        @sqlite.CachedSource::new(raw_wal, block_size=512, max_pages=2) :
        &@sqlite.RangeSource)
    } else {
      raw_wal
    }
    let source = @sqlite.RangeWalSource::new(
      source_base,
      source_wal,
      tail_policy=@sqlite.UseValidPrefix,
      max_frames=256,
      max_overlay_pages=1024,
    )
    check_database(
      @sqlite.open_range_wal_source(
        source,
        limits=fuzz_limits(),
        max_report_pages=1024,
      ),
      1,
    )
  } catch {
    @sqlite.Invalid(_) => "invalid"
    @sqlite.Unsupported(_) => "unsupported"
    @sqlite.LimitExceeded(_) => "limited"
  }
}

///|
fn wal_probe(base : Bytes, bytes : Bytes) -> String {
  let legacy = legacy_wal_probe(base, bytes)
  // 旧 WAL 源受 Int 字节长度限制；超出时仅要求范围入口之间保持一致。
  let addressable = try {
    let report = @sqlite.inspect_wal(bytes, max_frames=256)
    match (report.header, report.database_pages) {
      (Some(header), Some(pages)) =>
        pages.to_uint64() * header.page_size.to_uint64() <= 2147483647UL
      _ => true
    }
  } catch {
    _ => true
  }
  let expected = if addressable {
    legacy
  } else {
    range_wal_probe(base, bytes, false, false)
  }
  for adapter in [false, true] {
    for cached in [false, true] {
      let actual = range_wal_probe(base, bytes, adapter, cached)
      if actual != expected {
        abort(
          "WAL 范围覆盖源、适配器或缓存与旧入口差分不一致",
        )
      }
    }
  }
  fault_probe(bytes)
  report_fault_probe(bytes)
  wal_fault_probe(base, bytes)
  if expected == "invalid" || expected == "unsupported" || expected == "limited" {
    expected
  } else {
    "accepted"
  }
}

///|
priv struct FuzzFaultSource {
  data : Bytes
  short : Bool
  mut armed : Bool
}

///|
impl @sqlite.PageSource for FuzzFaultSource with fn byte_length(self) {
  self.data.length()
}

///|
impl @sqlite.PageSource for FuzzFaultSource with fn read_range(
  self,
  offset,
  count,
) {
  if !self.armed {
    return self.data[offset:offset + count].to_owned()
  }
  if !self.short {
    raise @sqlite.Invalid("确定性宿主故障")
  }
  self.data[offset:offset + count - 1].to_owned()
}

///|
impl @sqlite.RangeSource for FuzzFaultSource with fn byte_length64(self) {
  self.data.length().to_int64()
}

///|
impl @sqlite.RangeSource for FuzzFaultSource with fn read_range64(
  self,
  offset,
  count,
) {
  if !self.armed {
    return self.data[offset.to_int():offset.to_int() + count].to_owned()
  }
  if !self.short {
    raise @sqlite.HostFailure("确定性宿主故障")
  }
  self.data[offset.to_int():offset.to_int() + count - 1].to_owned()
}

///|
fn fault_probe(bytes : Bytes) -> Unit {
  if bytes.is_empty() {
    return
  }
  for short in [false, true] {
    for adapter in [false, true] {
      let raw = FuzzFaultSource::{ data: bytes, short, armed: true, }
      let source : &@sqlite.RangeSource = if adapter {
        (@sqlite.PageSourceAdapter::new(raw) : &@sqlite.RangeSource)
      } else {
        raw
      }
      let cache = @sqlite.CachedSource::new(source, block_size=512, max_pages=1) catch {
        _ => abort("故障缓存初始化失败")
      }
      for cached in [false, true] {
        let input : &@sqlite.RangeSource = if cached {
          (cache : &@sqlite.RangeSource)
        } else {
          source
        }
        let outcome = try {
          let data = input.read_range64(0L, Int::min(bytes.length(), 512))
          if !cached &&
            short &&
            data.length() == Int::min(bytes.length(), 512) - 1 {
            "short"
          } else {
            "unexpected"
          }
        } catch {
          @sqlite.ShortRead(_) => "short"
          @sqlite.HostFailure(_) => "host"
          @sqlite.RangeOutOfBounds(_) => "bounds"
        }
        if outcome != (if short { "short" } else { "host" }) {
          abort("范围故障或适配器分类不一致")
        }
        if cache.statistics().resident_pages != 0 {
          abort("宿主失败或短读进入了缓存")
        }
      }
    }
  }
}

///|
fn report_fault_probe(bytes : Bytes) -> Unit {
  if bytes.length() < 100 {
    return
  }
  for short in [false, true] {
    for adapter in [false, true] {
      for cached in [false, true] {
        if cached && bytes.length() <= 512 {
          continue
        }
        let raw = FuzzFaultSource::{ data: bytes, short, armed: false, }
        let adapted : &@sqlite.RangeSource = if adapter {
          (@sqlite.PageSourceAdapter::new(raw) : &@sqlite.RangeSource)
        } else {
          raw
        }
        let source : &@sqlite.RangeSource = if cached {
          (
            @sqlite.CachedSource::new(adapted, block_size=512, max_pages=1) catch {
              _ => abort("报告缓存初始化失败")
            } : &@sqlite.RangeSource)
        } else {
          adapted
        }
        let db = Some(
          @sqlite.open_range_source(
            source,
            limits=fuzz_limits(),
            max_report_pages=1024,
          ),
        ) catch {
          @sqlite.Invalid(_)
          | @sqlite.Unsupported(_)
          | @sqlite.LimitExceeded(_) => None
        }
        if db is Some(db) {
          if db.inspect_database().status != @sqlite.Complete {
            continue
          }
          // 淘汰初始化时的页头缓存，确保注入故障确实到达宿主。
          if cached {
            ignore(
              source.read_range64(bytes.length().to_int64() - 1L, 1) catch {
                _ => abort("缓存预热失败")
              },
            )
          }
          raw.armed = true
          let page = db.inspect_page(1)
          let tree = db.inspect_btree_details(1)
          if page.status != @sqlite.Incomplete ||
            tree.inspection.status != @sqlite.Incomplete {
            abort("源失败被单页或树报告误分类")
          }
          let expected_prefix = if short {
            "source/short_read:"
          } else {
            "source/host_failure:"
          }
          match tree.inspection.error {
            Some(@sqlite.Unsupported(message)) =>
              if !message.has_prefix(expected_prefix) {
                abort("故障诊断前缀不正确")
              }
            _ => abort("故障诊断丢失")
          }
          // 超出全局页预算时会先停在配置阶段，仍必须为 Incomplete。
          if db.inspect_database().status != @sqlite.Incomplete {
            abort("源失败被全局报告误分类")
          }
        }
      }
    }
  }
}

///|
fn wal_fault_probe(base : Bytes, bytes : Bytes) -> Unit {
  if bytes.length() < 32 {
    return
  }
  for short in [false, true] {
    for adapter in [false, true] {
      for cached in [false, true] {
        let raw = FuzzFaultSource::{ data: bytes, short, armed: true, }
        let adapted : &@sqlite.RangeSource = if adapter {
          (@sqlite.PageSourceAdapter::new(raw) : &@sqlite.RangeSource)
        } else {
          raw
        }
        let source : &@sqlite.RangeSource = if cached {
          (
            @sqlite.CachedSource::new(adapted, block_size=512, max_pages=1) catch {
              _ => abort("WAL 故障缓存初始化失败")
            } : &@sqlite.RangeSource)
        } else {
          adapted
        }
        let expected = if short {
          "source/short_read:"
        } else {
          "source/host_failure:"
        }
        let correct = try {
          ignore(
            @sqlite.RangeWalSource::new(
              @sqlite.BytesSource::new(base),
              source,
              tail_policy=@sqlite.UseValidPrefix,
              max_frames=256,
            ),
          )
          false
        } catch {
          @sqlite.Unsupported(message) => message.has_prefix(expected)
          _ => false
        }
        if !correct {
          abort("WAL 宿主故障被有效前缀策略吞掉或误分类")
        }
      }
    }
  }
}
