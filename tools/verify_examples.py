#!/usr/bin/env python3
"""从 README 与使用指南原文提取示例，在真实打包库的独立项目中运行。"""
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
    documents = {
        'README.md': {'read_rows'},
        'docs/usage.md': {'read_records', 'read_index', 'scan_records', 'inspect_file', 'read_committed'},
    }
    functions = []
    readme_blocks = []
    for name, expected in documents.items():
        blocks = re.findall(r'```moonbit\n(.*?)```', (ROOT/name).read_text(encoding='utf-8'), re.S)
        if name == 'README.md':
            readme_blocks = blocks
        examples = [block for block in blocks if block.lstrip().startswith('fn ')]
        names = [function for block in examples for function in re.findall(r'^fn\s+(\w+)\s*\(', block, re.M)]
        assert len(names) == len(set(names)), f'{name} 存在重复示例函数：{names}'
        assert set(names) == expected, f'{name} 示例函数缺失或变化：{names}'
        functions.extend(examples)
    with tempfile.TemporaryDirectory(prefix='document-consumer-',dir=ROOT/'_build') as temporary:
        workspace=Path(temporary)
        library=workspace/'library'; library.mkdir()
        with zipfile.ZipFile(archive) as package:
            assert all((library/name).resolve().is_relative_to(library.resolve()) for name in package.namelist())
            package.extractall(library)
        consumer=workspace/'consumer'; consumer.mkdir()
        (workspace/'moon.work').write_text('members = ["library", "consumer"]\n',encoding='utf-8')
        (consumer/'moon.mod').write_text(f'name = "docs/consumer"\nimport {{ "prowk/moonsqlitefile@{version}", }}\n',encoding='utf-8')
        imports = next(block for block in readme_blocks if block.lstrip().startswith('import '))
        (consumer/'moon.pkg').write_text(imports+'\npkgtype(kind: "executable")\n',encoding='utf-8')
        samples = {name:(ROOT/'fixtures'/f'{name}.sqlite').read_bytes() for name in ['core','btree']}
        (consumer/'data.mbt').write_text(moonbit_source(samples),encoding='utf-8')
        main = '''///|
fn main {
  try {
    let core = fixture_core()
    let btree = fixture_btree()
    if read_rows(core).length() != 6 { abort("README rowid 示例失败") }
    if read_records(btree).length() != 10 { abort("使用指南 WITHOUT ROWID 示例失败") }
    if read_index(btree).length() != 10 { abort("使用指南索引示例失败") }
    let scan = scan_records(core, 2, _ => true)
    if scan.records_read != 6 || scan.completion != @sqlite.Complete { abort("使用指南回调扫描失败") }
    if inspect_file(core).status != @sqlite.Complete { abort("使用指南全库报告失败") }
    if read_committed(core, b"").page_count() != 96 { abort("使用指南 WAL 示例失败") }
    println("Documentation examples passed")
  } catch {
    @sqlite.Invalid(message) | @sqlite.Unsupported(message) | @sqlite.LimitExceeded(message) => abort(message)
  }
}
'''
        (consumer/'main.mbt').write_text('\n\n'.join(functions)+'\n'+main,encoding='utf-8')
        for target in ['wasm','wasm-gc','js','native']:
            assert 'Documentation examples passed' in run(['moon','run','--target',target,'.'],consumer)
    for target in ['wasm','wasm-gc','js','native']:
        assert 'schema entries=0' in run(['moon','run','--target',target,'src/examples/basic'],ROOT)
        assert 'claimed pages=1' in run(['moon','run','--target',target,'src/examples/cursors'],ROOT)
    output = run(['node','adapters/async/example.mjs','fixtures/core.sqlite'],ROOT)
    assert 'complete' in output, output
    print('Verified one README and five usage-guide examples on four backends and independent async example')


if __name__ == '__main__':
    main()
