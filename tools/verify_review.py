#!/usr/bin/env python3
"""将审查中确认的空间误拒、空子页漏检与 CLI 消息缺失纳入 SQLite 差分回归。"""
from pathlib import Path
import sqlite3
import subprocess
import json
import random
import tempfile
from contextlib import closing
ROOT = Path(__file__).resolve().parents[1]

def cli(path, *args):
    result = subprocess.run(['node', str(ROOT / 'tools/inspect.cjs'), str(path), *map(str, args)], cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=30)
    try:
        value = json.loads(result.stdout)
    except ValueError:
        value = result.stderr.strip()
    return (result.returncode, value)

def verify(directory):
    OUT = directory
    for i in range(54):
        rng = random.Random(i)
        p = OUT / f'legal-{i}.db'
        with closing(sqlite3.connect(p)) as db:
            size = [512, 1024, 4096, 65536][i % 4]
            mode = i // 4 % 3
            db.execute(f'pragma page_size={size}')
            db.execute(f'pragma auto_vacuum={mode}')
            db.execute("pragma encoding='" + ['UTF-8', 'UTF-16le', 'UTF-16be'][i % 3] + "'")
            db.execute('create table t(k integer primary key, x text, y blob)')
            db.execute('create index ix on t(x desc,k)')
            db.execute('create table w(a text,b integer,c blob,primary key(a desc,b)) without rowid')
            for n in range(160):
                x = ['', '\ufeffabc', '\ufffe中文', '\x00a', '😀', '中' * rng.randrange(1, 300)][n % 6]
                db.execute('insert into t values(?,?,?)', (n - 80, x, bytes((rng.randrange(256) for _ in range(rng.randrange(0, 1200))))))
                db.execute('insert into w values(?,?,?)', (x, n, b'x' * rng.randrange(500)))
            db.commit()
            db.execute('delete from t where k%3=0')
            db.execute('delete from w where b%4=0')
            db.commit()
            db.execute('update t set x=substr(x,1,2),y=zeroblob(abs(k)*3) where k%2=0')
            db.commit()
            expected = db.execute('select k,x,hex(y) from t order by k').fetchall()
            integrity = db.execute('pragma integrity_check').fetchall()
        code, report = cli(p, 'inspect')
        rowcode, rows = cli(p, 'rows', 't')
        mismatch = None
        if rowcode == 0:
            actual = [(int(r['rowid']), r['values'][1]['value'], r['values'][2]['value'].upper()) for r in rows]
            if actual != expected:
                mismatch = 'rows mismatch'
        if code or rowcode or mismatch or (integrity != [('ok',)]):
            row = dict(case=p.name, oracle=integrity, actual=[code, report], rows=[rowcode, rows] if rowcode else mismatch)
            raise AssertionError(json.dumps(row, ensure_ascii=False))
    original = directory / 'children.db'
    with closing(sqlite3.connect(original)) as db:
        db.execute('pragma page_size=512')
        db.execute('create table t(x integer)')
        db.executemany('insert into t values(?)', [(i,) for i in range(300)])
        db.commit()
        assert db.execute('pragma integrity_check').fetchall() == [('ok',)]
    data = bytearray(original.read_bytes())
    child = next((n for n in range(3, len(data) // 512 + 1) if data[(n - 1) * 512] == 13))
    offset = (child - 1) * 512
    data[offset:offset + 512] = bytes.fromhex('0d00000000020000') + bytes(504)
    damaged = directory / 'empty-child.db'
    damaged.write_bytes(data)
    with closing(sqlite3.connect(damaged)) as db:
        try:
            assert db.execute('pragma integrity_check').fetchall() != [('ok',)]
        except sqlite3.DatabaseError as error:
            assert 'malformed' in str(error)
    for command in [('tree-inspect', 2), ('inspect',), ('rows', 't')]:
        code, result = cli(damaged, *command)
        assert code == 1, (command, result)
        if isinstance(result, dict):
            assert result['status'] == 'failed'
    for command, message in [(('rows', 'does_not_exist'), 'does_not_exist'), (('page', 999999), '999999'), (('rows', 'samples', 100001), '记录数请求超出资源限制')]:
        code, result = cli(ROOT / 'fixtures/core.sqlite', *command)
        assert code == 1 and message in result and (':' in result), (command, result)
    unsupported = directory / 'unsupported.db'
    data = bytearray((ROOT / 'fixtures/core.sqlite').read_bytes())
    data[19] = 3
    unsupported.write_bytes(data)
    code, result = cli(unsupported, 'header')
    assert code == 1 and 'unsupported:' in result and ('未知文件读取版本' in result)
    print('Verified review fixes: 54 legal SQLite DML cases, empty child corruption, three CLI error categories')
if __name__ == '__main__':
    (ROOT / '_build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='review-regression-', dir=ROOT / '_build') as temporary:
        verify(Path(temporary))
