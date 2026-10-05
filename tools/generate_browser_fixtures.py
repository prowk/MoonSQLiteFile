#!/usr/bin/env python3
"""生成浏览器验收的静态 SQLite/WAL 副本及超过 64 MiB 的合法数据库。"""
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import verify_wal_oracle as oracle

ROOT = Path(__file__).resolve().parents[1]


def main():
    output = ROOT / '_build/browser-acceptance'
    output.mkdir(exist_ok=True)
    large = output / 'large.sqlite'
    if large.exists():
        large.unlink()
    with closing(sqlite3.connect(large)) as db:
        db.execute('create table t(v blob)')
        db.executemany('insert into t values(zeroblob(65536))', [()] * 1100)
        db.commit()
        assert db.execute('pragma integrity_check').fetchone() == ('ok',)
        page_count = db.execute('pragma page_count').fetchone()[0]
    with tempfile.TemporaryDirectory(prefix='browser-wal-', dir=ROOT / '_build') as temporary:
        for name, base, wal in oracle.scenarios(Path(temporary)):
            if name not in ('512-transactions', 'shrink', '512-reset'):
                continue
            (output / f'{name}.db').write_bytes(base)
            (output / f'{name}.wal').write_bytes(wal)
    damaged = bytearray((ROOT / 'fixtures/btree.sqlite').read_bytes())
    damaged[107] = 61
    (output / 'damaged.sqlite').write_bytes(damaged)
    (output / 'short.sqlite').write_bytes(bytes(32))
    evidence = dict(database_bytes=large.stat().st_size, records=1100, logical_pages=page_count,
                    integrity_check='ok')
    (output / 'fixtures.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(evidence))


if __name__ == '__main__':
    main()
