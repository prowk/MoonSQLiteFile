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
        (consumer / "main.mbt").write_text(main_source, encoding="utf-8")
        if args.registry:
            run(["moon", "update"], consumer)
        for action in ("check", "build", "test"):
            run(["moon", action, "--target", "all", "--deny-warn"], consumer)
        output = run(["moon", "run", "--target", "js", "."], consumer)
        assert output.strip() == "pages=1, schema=0", output
    print(f"Verified {'registry' if args.registry else 'packaged'} consumer: {name}@{version}, four backends")


if __name__ == "__main__":
    main()
