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
                    assert normalized not in {"AGENTS.md", "docs/proposal.md", "tools/github_publish.py"}, f"发布包包含本地文件：{relative}"
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
