#!/usr/bin/env python3
"""在独立工作区验证实际发布包可由外部 MoonBit 项目使用。"""
from pathlib import Path
import argparse
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(command, cwd):
    result = subprocess.run(command, cwd=cwd, text=True, encoding="utf-8", capture_output=True)
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", metavar="VERSION", help="从 Mooncakes 安装指定版本，验证真实消费流程")
    args = parser.parse_args()
    manifest = (ROOT / "moon.mod").read_text(encoding="utf-8")
    name = re.search(r'^name = "([^"]+)"', manifest, re.M)[1]
    version = args.registry or re.search(r'^version = "([^"]+)"', manifest, re.M)[1]
    if not args.registry:
        run(["moon", "package"], ROOT)
    archive = ROOT / "_build" / "publish" / f"{name.replace('/', '-')}-{version}.zip"
    build_root = ROOT / "_build"
    build_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="consumer-", dir=build_root) as temporary:
        workspace = Path(temporary)
        library = workspace / "library"
        library.mkdir()
        if not args.registry:
            with zipfile.ZipFile(archive) as package:
                names = package.namelist()
                if tuple(map(int,version.split('.')[:2])) >= (0,8):
                    assert {'moon.mod','src/moon.pkg','src/pkg.generated.mbti','src/examples/cursors/main.mbt'} <= set(names)
                    assert 'moon.pkg' not in names and 'pkg.generated.mbti' not in names
                    assert not any(path.startswith(('src/cmd/fuzz/','src/cmd/async-bridge/','adapters/','fixtures/cli-contract/','fixtures/regressions/')) for path in names)
                    packaged_manifest=package.read('moon.mod').decode('utf-8')
                    assert 'source = "src"' in packaged_manifest
                for relative in names:
                    normalized = relative.replace("\\", "/")
                    assert normalized not in {"AGENTS.md", "docs/roadmap.md", "docs/proposal.md", "tools/github_publish.py"}, f"发布包包含本地文件：{relative}"
                    # 解包路径必须留在为本次检查创建的临时目录中。
                    assert (library / normalized).resolve().is_relative_to(library.resolve())
                package.extractall(library)
        consumer = workspace / "consumer"
        consumer.mkdir()
        if not args.registry:
            (workspace / "moon.work").write_text('members = ["library", "consumer"]\n', encoding="utf-8")
        (consumer / "moon.mod").write_text(f'name = "consumer/check"\n\nimport {{\n  "{name}@{version}",\n}}\n', encoding="utf-8")
        (consumer / "moon.pkg").write_text(f'import {{\n  "{name}" @sqlite,\n}}\npkgtype(kind: "executable")\n', encoding="utf-8")
        main_source = '''///|
fn main {
  // 宿主传入完整文件字节，独立消费项目无需 SQLite 引擎或文件系统依赖。
  let header = b"SQLite format 3\\x00\\x02\\x00\\x01\\x01\\x00\\x40\\x20\\x20" + Bytes::make(76, 0)
  let data = header + b"\\x0d\\x00\\x00\\x00\\x00\\x02\\x00\\x00" + Bytes::make(404, 0)
  try {
    let db = @sqlite.open_database(data)
    println("pages=\\{db.page_count()}, schema=\\{db.schema().length()}")
  } catch {
    @sqlite.Invalid(message) | @sqlite.Unsupported(message) | @sqlite.LimitExceeded(message) => abort(message)
    _ => abort("未预期的宿主错误")
  }
}
'''
        if tuple(map(int, version.split(".")[:2])) >= (0, 2):
            main_source = '''///|
priv struct ConsumerSource { data : Bytes }
///|
impl @sqlite.PageSource for ConsumerSource with byte_length(self) { self.data.length() }
///|
impl @sqlite.PageSource for ConsumerSource with read_range(self, offset, count) {
  if offset < 0 || count < 0 || offset > self.data.length() || count > self.data.length() - offset {
    raise @sqlite.Invalid("宿主读取越界")
  }
  self.data[offset:offset + count].to_owned()
}
\n''' + main_source.replace('@sqlite.open_database(data)', '@sqlite.open_source(ConsumerSource::{data,})')
        if tuple(map(int, version.split(".")[:2])) >= (0, 3):
            main_source = main_source.replace('    println(', '''    let report = db.inspect_database()
    if report.status != @sqlite.Complete || !report.ownership_complete || !report.ptrmap_checked || report.pages.length() != 1 || !db.ptrmap_entries().is_empty() {
      abort("独立消费项目的全局检查失败")
    }
    if db.inspect_btree(1).status != @sqlite.Complete {
      abort("独立消费项目的单树检查失败")
    }
    println(''')
        if not args.registry or tuple(map(int, version.split(".")[:2])) >= (0, 4):
            # 当前包及真实 v0.4+ registry 消费均验证新增 API，历史版本保持各自范围。
            main_source = main_source.replace('    println(', '''    let page = db.inspect_page(1)
    if page.status != @sqlite.Complete || page.page is None || page.diagnostic is Some(_) {
      abort("独立消费项目的页面检查失败")
    }
    let stats = page.statistics.unwrap()
    if stats.database_header_bytes != 100 || stats.unallocated_bytes != 404 || stats.payload_bytes != 0UL {
      abort("独立消费项目的页面统计失败")
    }
    let missing = db.inspect_page(2)
    if missing.status != @sqlite.Incomplete || missing.diagnostic.unwrap().code != @sqlite.PageRead {
      abort("独立消费项目的页面诊断失败")
    }
    let tree = db.inspect_btree_details(1)
    if tree.inspection.status != @sqlite.Complete || tree.location is Some(_) {
      abort("独立消费项目的详细树报告失败")
    }
    let detailed = db.inspect_database_details()
    if detailed.inspection.status != @sqlite.Complete || !detailed.issues.is_empty() {
      abort("独立消费项目的详细数据库报告失败")
    }
    if db.inspect_btree_details(2).location.unwrap().phase != @sqlite.ReadPage {
      abort("独立消费项目的树读取定位失败")
    }
    // 保留旧版公开结构的直接构造能力，并在外部项目编译消费。
    let legacy_tree : @sqlite.BTreeInspection = {
      root_page: 1, status: @sqlite.Complete, records_decoded: 0,
      summary: None, error: None,
    }
    let current = detailed.inspection
    let legacy_report : @sqlite.DatabaseInspection = {
      status: current.status, ownership_complete: current.ownership_complete,
      ptrmap_checked: current.ptrmap_checked,
      diagnostics_truncated: current.diagnostics_truncated,
      roots_inspected: current.roots_inspected, records_decoded: current.records_decoded,
      payload_bytes: current.payload_bytes, pages: current.pages,
      unclaimed_pages: current.unclaimed_pages, issues: current.issues,
    }
    if legacy_tree.root_page != 1 || legacy_report.status != @sqlite.Complete {
      abort("旧版报告构造失败")
    }
    let summary = legacy_report.summarize()
    if summary.claimed_pages != 1 || summary.unclaimed_pages != 0 || summary.page_kinds.length() != 8 || summary.objects.length() != 1 {
      abort("独立消费项目的页分类汇总失败")
    }
    if summary.objects[0].object_name != Some("sqlite_schema") || summary.objects[0].btree_pages != 1 {
      abort("独立消费项目的对象占页汇总失败")
    }
    println(''')
        if not args.registry or tuple(map(int, version.split(".")[:2])) >= (0, 5):
            main_source = main_source.replace('    println(', '''    let payload = data.to_array()
    payload[63] = 11
    let wal = b"\\x37\\x7f\\x06\\x83\\x00\\x2d\\xe2\\x18\\x00\\x00\\x02\\x00\\x00\\x00\\x00\\x11\\x11\\x22\\x33\\x44\\x55\\x66\\x77\\x88\\x27\\x26\\xfe\\x2c\\x23\\x66\\x4f\\x7e\\x00\\x00\\x00\\x01\\x00\\x00\\x00\\x01\\x11\\x22\\x33\\x44\\x55\\x66\\x77\\x88\\x49\\x40\\x5d\\xe6\\xbc\\xc9\\x5c\\x00" + Bytes::from_array(payload)
    if @sqlite.parse_wal_header(wal).checksum_order != @sqlite.BigEndianChecksum {
      abort("独立消费项目的 WAL header 验证失败")
    }
    let inspection = @sqlite.inspect_wal(wal)
    if inspection.committed_frames != 1 || inspection.database_pages != Some(1U) || inspection.stop_reason != @sqlite.WalEndOfFile {
      abort("独立消费项目的 WAL 帧报告失败")
    }
    let source = @sqlite.WalSource::new(ConsumerSource::{data,}, wal)
    if source.byte_length() != 512 || source.page_count() != 1 || source.read_range(60,4) != b"\\x00\\x00\\x00\\x0b" || source.inspection().commits.length() != 1 {
      abort("第三方数据源的 WAL 覆盖失败")
    }
    let snapshot = @sqlite.open_wal_source(source)
    if snapshot.header().user_version != 11U || snapshot.inspect_database().status != @sqlite.Complete {
      abort("独立消费项目的 WAL 快照检查失败")
    }
    if @sqlite.open_wal_database(data, wal, tail_policy=@sqlite.UseValidPrefix).header().user_version != 11U || @sqlite.open_wal_database(data,b"").page_count() != 1 {
      abort("内存 WAL 与空日志消费失败")
    }
    println(''')
        if not args.registry or tuple(map(int, version.split(".")[:2])) >= (0, 6):
            # 外部项目自行实现 RangeSource，并构造所有宿主错误分支。
            main_source = """///|
priv struct ConsumerRange { data : Bytes }
///|
impl @sqlite.RangeSource for ConsumerRange with byte_length64(self) { self.data.length().to_int64() }
///|
impl @sqlite.RangeSource for ConsumerRange with read_range64(self, offset, count) {
  if offset < 0L || offset > self.data.length().to_int64() || count < 0 || count.to_int64() > self.data.length().to_int64() - offset {
    raise @sqlite.RangeOutOfBounds("消费项目范围越界")
  }
  let start = offset.to_int()
  self.data[start:start + count].to_owned()
}
///|
priv struct ConsumerFailure {}
///|
impl @sqlite.RangeSource for ConsumerFailure with byte_length64(_) { 512L }
///|
impl @sqlite.RangeSource for ConsumerFailure with read_range64(_, _, count) {
  if count == 100 {
    return b"SQLite format 3\\x00\\x02\\x00\\x01\\x01\\x00\\x40\\x20\\x20" + Bytes::make(76, 0)
  }
  raise @sqlite.HostFailure("消费项目模拟磁盘失败")
}
""" + main_source
            main_source = main_source.replace('    println(', '''    let {source: legacy_source, header: legacy_header, page_count: legacy_pages, limits: legacy_limits} = db
    if legacy_source.byte_length() != 512 || legacy_header.page_size != 512 || legacy_pages != 1 || legacy_limits.max_pages != 100000 {
      abort("历史 Database 字段读取与解构失败")
    }
    if db.source64().byte_length64() != 512L { abort("完整范围源访问失败") }
    let range = ConsumerRange::{data,}
    let cache = @sqlite.CachedSource::new(range, block_size=512, max_pages=1)
    let wide = @sqlite.open_range_source(cache, max_report_pages=1)
    if wide.header() != db.header() || wide.inspect_database().status != @sqlite.Complete || cache.statistics().resident_pages != 1 {
      abort("独立范围数据源与缓存消费失败")
    }
    let adapted = @sqlite.PageSourceAdapter::new(ConsumerSource::{data,})
    if @sqlite.open_range_source(adapted).page_count() != 1 || adapted.read_range64(0L, 16) != data[0:16].to_owned() {
      abort("旧 PageSource 适配消费失败")
    }
    let journal = ConsumerRange::{data: wal,}
    let range_wal = @sqlite.RangeWalSource::new(range, journal, max_overlay_pages=1)
    if range_wal.byte_length64() != 512L || @sqlite.open_range_wal_source(range_wal).header().user_version != 11U || @sqlite.inspect_wal_source(journal).committed_frames != 1 {
      abort("独立范围 WAL 消费失败")
    }
    let failed = @sqlite.open_range_source(ConsumerFailure::{})
    if failed.inspect_btree(1).status != @sqlite.Incomplete || failed.inspect_database().status != @sqlite.Incomplete {
      abort("宿主读取失败的部分报告契约错误")
    }
    let host_error : @sqlite.SourceError = @sqlite.ShortRead("消费项目短读")
    match host_error { @sqlite.ShortRead(_) => (); _ => abort("宿主错误构造失败") }
    println(''')
        if not args.registry or tuple(map(int, version.split(".")[:2])) >= (0, 7):
            main_source = main_source.replace('    println(', '''    let cursor = db.scan_cursor(1, table_only=true)
    match cursor.next() { @sqlite.NeedPage(1) => (); _ => abort("独立游标未请求根页") }
    cursor.provide_page(1, data)
    match cursor.next() { @sqlite.ScanFinished(summary) if summary.completion == @sqlite.Complete => (); _ => abort("独立扫描游标失败") }
    let global = db.inspection_cursor()
    while true {
      match global.next() {
        @sqlite.NeedInspectionPage(1) => global.provide_page(1, data)
        @sqlite.NeedInspectionPage(_) => abort("空库不应读取其他页")
        @sqlite.InspectionProgress(_) => ()
        @sqlite.InspectionFinished(details) => { if details.inspection.status != @sqlite.Complete { abort("全库游标消费失败") }; break }
      }
    }
    let wal_cursor = @sqlite.WalCursor::new(wal.length().to_int64())
    while true {
      match wal_cursor.next() {
        @sqlite.NeedWalRange(offset, count) => { let start = offset.to_int(); wal_cursor.provide(offset, wal[start:start + count].to_owned()) }
        @sqlite.WalReady(_) => break
      }
    }
    let snapshot_range = @sqlite.RangeWalSource::from_cursor(range, journal, wal_cursor)
    match snapshot_range.page_range(1) { @sqlite.WalPage(56L) => (); _ => abort("异步覆盖页来源消费失败") }
    wal_cursor.close()
    println(''')
        (consumer / "main.mbt").write_text(main_source, encoding="utf-8")
        if args.registry:
            run(["moon", "update"], consumer)
        for action in ("check", "build", "test"):
            run(["moon", action, "--target", "all", "--deny-warn"], consumer)
        for backend in ("wasm", "wasm-gc", "js", "native"):
            output = run(["moon", "run", "--target", backend, "."], consumer)
            assert output.strip() == "pages=1, schema=0", output
    print(f"Verified {'registry' if args.registry else 'packaged'} consumer: {name}@{version}, four backends")


if __name__ == "__main__":
    main()
