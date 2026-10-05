#!/usr/bin/env python3
"""持续重放历史 fuzz 的小规模边界输入；不将正常错误误记为崩溃。"""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    directory=ROOT/'fixtures/regressions'
    cases=json.loads((directory/'manifest.json').read_text(encoding='utf-8'))
    for case in cases:
        path=directory/(case['name']+'.sqlite')
        metadata=json.loads(path.with_suffix('.json').read_text(encoding='utf-8'))
        base=path.with_suffix('.base.sqlite').read_bytes() if metadata['kind']=='wal' else b''
        assert hashlib.sha256(path.read_bytes()+base).hexdigest()==metadata['sha256']
        assert path.stat().st_size==case['bytes']<=case['original_bytes']
        result=subprocess.run(['node','tools/fuzz.cjs','--replay',str(path)],cwd=ROOT,
                              capture_output=True,text=True,encoding='utf-8',timeout=30)
        assert result.returncode==0,result.stdout+result.stderr
        counts=json.loads(result.stdout.split('results=')[-1])
        assert counts=={case['expected']:1},(case,counts)
    print(f'Verified {len(cases)} retained/minimized historical fuzz boundary inputs')


if __name__ == '__main__':
    main()
