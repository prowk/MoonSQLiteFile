#!/usr/bin/env python3
"""在独立工作区验证实际发布包可由外部 MoonBit 项目使用。"""
from pathlib import Path
import os
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
    manifest = (ROOT / "moon.mod").read_text(encoding="utf-8")
    name = re.search(r'^name = "([^"]+)"', manifest, re.M)[1]
    version = re.search(r'^version = "([^"]+)"', manifest, re.M)[1]
    run(["moon", "package"], ROOT)
    archive = ROOT / "_build" / "publish" / f"{name.replace('/', '-')}-{version}.zip"
    build_root = ROOT / "_build"
    build_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="consumer-", dir=build_root) as temporary:
        workspace = Path(temporary)
        library = workspace / "library"
        library.mkdir()
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
        (workspace / "moon.work").write_text('members = ["library", "consumer"]\n', encoding="utf-8")
        (consumer / "moon.mod").write_text(f'name = "consumer/check"\n\nimport {{\n  "{name}@{version}",\n}}\n', encoding="utf-8")
        (consumer / "moon.pkg").write_text(f'import {{\n  "{name}" @sqlite,\n}}\npkgtype(kind: "executable")\n', encoding="utf-8")
        (consumer / "main.mbt").write_text('''///|
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
''', encoding="utf-8")
        for action in ("check", "build", "test"):
            run(["moon", action, "--target", "all", "--deny-warn"], consumer)
        output = run(["moon", "run", "--target", "js", "."], consumer)
        assert output.strip() == "pages=1, schema=0", output
    print(f"Verified packaged consumer: {name}@{version}, four backends")


if __name__ == "__main__":
    main()
