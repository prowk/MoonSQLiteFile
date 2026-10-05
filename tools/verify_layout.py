#!/usr/bin/env python3
"""核实源码目录、公开文档、测试隔离及打包路径，防止迁移仅在本地构建成功。"""
from pathlib import Path
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    manifest = (ROOT/'moon.mod').read_text(encoding='utf-8')
    assert 'source = "src"' in manifest
    assert 'name = "prowk/moonsqlitefile"' in manifest
    assert not list(ROOT.glob('*.mbt')) and not (ROOT/'moon.pkg').exists()
    assert (ROOT/'src/pkg.generated.mbti').exists()
    assert not (ROOT/'cmd').exists() and not (ROOT/'examples/basic').exists()
    symbols = []
    for path in (ROOT/'src').glob('*.mbt'):
        text = path.read_text(encoding='utf-8')
        assert '\ufffd' not in text, path
        if path.name.endswith(('_test.mbt','_wbtest.mbt')):
            continue
        for block in text.split('///|'):
            match = re.search(r'^pub(?:\([^)]*\))? (?:fn|struct|enum|suberror|trait) ([\w:]+)',block,re.M)
            if not match:
                continue
            prefix = block[:match.start()]
            assert re.search(r'^///\s+\S',prefix,re.M), f'公开符号缺少契约注释：{path.name}:{match[1]}'
            symbols.append(match[1])
    assert len(symbols) == 124, len(symbols)
    subprocess.run(['moon','doc'],cwd=ROOT,check=True,capture_output=True)
    rendered=json.loads((ROOT/'_build/doc/prowk/moonsqlitefile/package_data.json').read_text(encoding='utf-8'))
    assert rendered['name']=='prowk/moonsqlitefile'
    for section in ['traits','errors','types','values']:
        for item in rendered[section]:
            assert item.get('docstring','').strip(), f"生成的公开文档为空：{item['name']}"
    for item in rendered['types']:
        for method in item.get('methods',[]):
            if method['name'] in {'scan_cursor','inspection_cursor','provide_page','reject_page','from_cursor','page_range','next','stop','close','source64'}:
                assert method.get('docstring','').strip(), f"生成的游标文档为空：{item['name']}::{method['name']}"
    for target in ['wasm','wasm-gc','js','native']:
        plan = subprocess.check_output(['moon','build','--dry-run','--target',target,'src'],cwd=ROOT,text=True,encoding='utf-8')
        assert '-pkg prowk/moonsqlitefile ' in plan
        assert '_wbtest.mbt' not in plan and '_test.mbt' not in plan, '正常库构建混入测试源码'
    # 供给字节仍是白盒测试源码；不让消费者新增文件系统或生成器依赖。
    fixtures = ['fixture_bytes_wbtest.mbt','btree_fixture_wbtest.mbt']
    evidence = {'source':'src','import_path':'prowk/moonsqlitefile','documented_symbols':len(symbols),
                'whitebox_files':len(list((ROOT/'src').glob('*_wbtest.mbt'))),
                'blackbox_files':len(list((ROOT/'src').glob('*_test.mbt'))),
                'embedded_test_source_bytes':sum((ROOT/'src'/name).stat().st_size for name in fixtures),
                'normal_build_excludes_tests':True}
    (ROOT/'_build/layout-evidence.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
    print(f"Verified layout and documentation: {len(symbols)} public symbols, four normal builds exclude tests")


if __name__ == '__main__':
    main()
