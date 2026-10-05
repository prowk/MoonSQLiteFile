#!/usr/bin/env python3
"""从 README 原文提取示例，使用真实打包库在独立项目中编译并运行。"""
from pathlib import Path
import json
import re
import subprocess
import tempfile
import zipfile
from generate_fixtures import moonbit_source

ROOT = Path(__file__).resolve().parents[1]


def run(command, cwd):
    result = subprocess.run(command,cwd=cwd,capture_output=True,text=True,encoding='utf-8',timeout=180)
    if result.returncode:
        raise SystemExit(result.stdout+result.stderr)
    return result.stdout


def main():
    manifest = (ROOT/'moon.mod').read_text(encoding='utf-8')
    version = re.search(r'^version = "([^"]+)"',manifest,re.M)[1]
    run(['moon','package'],ROOT)
    archive = ROOT/'_build/publish'/f'prowk-moonsqlitefile-{version}.zip'
    blocks = re.findall(r'```moonbit\n(.*?)```',(ROOT/'README.md').read_text(encoding='utf-8'),re.S)
    functions = [block for block in blocks if block.lstrip().startswith('fn ')]
    assert sum(len(re.findall(r'^fn ',block,re.M)) for block in functions) == 6, 'README 示例变化后须同步运行场景'
    with tempfile.TemporaryDirectory(prefix='document-consumer-',dir=ROOT/'_build') as temporary:
        workspace=Path(temporary)
        library=workspace/'library'; library.mkdir()
        with zipfile.ZipFile(archive) as package:
            assert all((library/name).resolve().is_relative_to(library.resolve()) for name in package.namelist())
            package.extractall(library)
        consumer=workspace/'consumer'; consumer.mkdir()
        (workspace/'moon.work').write_text('members = ["library", "consumer"]\n',encoding='utf-8')
        (consumer/'moon.mod').write_text(f'name = "docs/consumer"\nimport {{ "prowk/moonsqlitefile@{version}", }}\n',encoding='utf-8')
        imports = next(block for block in blocks if block.lstrip().startswith('import '))
        (consumer/'moon.pkg').write_text(imports+'\npkgtype(kind: "executable")\n',encoding='utf-8')
        samples = {name:(ROOT/'fixtures'/f'{name}.sqlite').read_bytes() for name in ['core','btree']}
        (consumer/'data.mbt').write_text(moonbit_source(samples),encoding='utf-8')
        main = '''///|
fn main {
  try {
    let core = fixture_core()
    let btree = fixture_btree()
    if read_rows(core).length() != 6 { abort("README rowid 示例失败") }
    if read_records(btree).length() != 10 { abort("README WITHOUT ROWID 示例失败") }
    if read_index(btree).length() != 10 { abort("README 索引示例失败") }
    let scan = scan_records(core, 2, _ => true)
    if scan.records_read != 6 || scan.completion != @sqlite.Complete { abort("README 回调扫描失败") }
    if inspect_file(core).status != @sqlite.Complete { abort("README 全库报告失败") }
    if read_committed(core, b"").page_count() != 96 { abort("README WAL 示例失败") }
    println("README examples passed")
  } catch {
    @sqlite.Invalid(message) | @sqlite.Unsupported(message) | @sqlite.LimitExceeded(message) => abort(message)
  }
}
'''
        (consumer/'main.mbt').write_text('\n\n'.join(functions)+'\n'+main,encoding='utf-8')
        for target in ['wasm','wasm-gc','js','native']:
            assert 'README examples passed' in run(['moon','run','--target',target,'.'],consumer)
    for target in ['wasm','wasm-gc','js','native']:
        assert 'schema entries=0' in run(['moon','run','--target',target,'src/examples/basic'],ROOT)
        assert 'claimed pages=1' in run(['moon','run','--target',target,'src/examples/cursors'],ROOT)
    output = run(['node','adapters/async/example.mjs','fixtures/core.sqlite'],ROOT)
    assert 'complete' in output, output
    print('Verified six README examples on four backends and independent async example')


if __name__ == '__main__':
    main()
