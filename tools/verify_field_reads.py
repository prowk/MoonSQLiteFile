#!/usr/bin/env python3
"""生成跨页记录头、大字段和字符边界样本，验证有限读取路径。"""
from contextlib import closing
from pathlib import Path
import sqlite3
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    output = ROOT / '_build/field-read-fixtures'
    output.mkdir(exist_ok=True)
    for encoding in ('UTF-8', 'UTF-16le', 'UTF-16be'):
        path = output / f'{encoding}.sqlite'
        path.unlink(missing_ok=True)
        with closing(sqlite3.connect(path)) as db:
            db.execute('pragma page_size=512')
            db.execute(f"pragma encoding='{encoding}'")
            db.execute('create table t(v text, b blob, tail text)')
            db.execute('insert into t values(?, zeroblob(20000), ?)', ('🍙中' * 1000, '末尾🍙'))
            db.commit()
            assert db.execute('pragma integrity_check').fetchone() == ('ok',)
    wide = output / 'header.sqlite'
    wide.unlink(missing_ok=True)
    with closing(sqlite3.connect(wide)) as db:
        db.execute('pragma page_size=512')
        db.execute('create table t(' + ','.join(f'c{i}' for i in range(1800)) + ')')
        db.execute('insert into t values(' + ','.join('?' for _ in range(1800)) + ')', [None] * 1799 + ['最后'])
        db.commit()
        assert db.execute('pragma integrity_check').fetchone() == ('ok',)
    huge = output / 'huge.sqlite'
    huge.unlink(missing_ok=True)
    with closing(sqlite3.connect(huge)) as db:
        db.execute('create table t(b blob, s text)')
        db.execute('insert into t values(zeroblob(25165824), ?)', ('未选择文本',))
        db.commit()
        assert db.execute('pragma integrity_check').fetchone() == ('ok',)
    subprocess.run(['node', 'tools/verify_field_reads.mjs'], cwd=ROOT, check=True)
    print('SQLite-produced crossing headers, >16 MiB fields and UTF-8/UTF-16 fixtures passed')


if __name__ == '__main__':
    main()
