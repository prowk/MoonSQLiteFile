#!/usr/bin/env python3
"""核实固定工具链或独立 latest 验收通道，并保存真实环境证据。"""
from pathlib import Path
import json
import os
import platform
import re
import sqlite3
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    pinned = json.loads((ROOT/'tools/toolchain.json').read_text(encoding='utf-8'))
    channel = os.environ.get('MOONSQLITE_TOOLCHAIN_CHANNEL','pinned')
    assert channel in {'pinned','latest'}
    moon = subprocess.check_output(['moon','version','--all'],text=True,encoding='utf-8')
    node = subprocess.check_output(['node','--version'],text=True).strip().removeprefix('v')
    if channel == 'pinned':
        assert re.search(r'^moon '+re.escape(pinned['moon'])+r' \('+pinned['moon_commit'],moon,re.M), moon
        assert 'moonc '+pinned['moonc'] in moon, moon
        assert 'moonrun '+pinned['moonrun'] in moon, moon
    assert node == pinned['node'], f'Node 与固定验收版本不符：{node}'
    assert platform.python_version() == pinned['python'], f'Python 与固定验收版本不符：{platform.python_version()}'
    evidence = {'channel':channel,'platform':platform.platform(),'moon':moon.strip(),
                'node':node,'python':platform.python_version(),'sqlite':sqlite3.sqlite_version}
    output = ROOT/'_build'/f'toolchain-{channel}.json'; output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f'Verified {channel} toolchain; Node {node}, Python {platform.python_version()}, SQLite {sqlite3.sqlite_version}')


if __name__ == '__main__':
    main()
