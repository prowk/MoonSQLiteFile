#!/usr/bin/env python3
"""生成浏览器验收的静态 SQLite/WAL 副本及超过 64 MiB 的合法数据库。"""
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import shutil
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
    objects = output/'objects.sqlite'
    objects.unlink(missing_ok=True)
    with closing(sqlite3.connect(objects)) as db:
        name = '用户事件记录_'+'较长的对象名称'*20
        db.execute(f'create table "{name}"(id integer primary key, value text)')
        db.executemany(f'insert into "{name}" values (?, ?)', [(index, '静态事件') for index in range(5)])
        db.execute(f'create view event_view as select * from "{name}"')
        db.execute(f'create trigger event_trigger after insert on "{name}" begin select 1; end')
        db.execute('create virtual table event_search using fts5(value)')
        db.commit()
        assert db.execute('pragma integrity_check').fetchone() == ('ok',)
    # 先生成中等大值基线，再生成百 MiB、宽记录和大量小记录，均由 SQLite 验证。
    samples = {}
    for name, count, size in [('blob-batch.sqlite', 8, 4194304), ('hundred-mib.sqlite', 16, 8388608)]:
        path = output/name; path.unlink(missing_ok=True)
        with closing(sqlite3.connect(path)) as db:
            db.execute('create table payloads(id integer primary key, value blob)')
            db.executemany('insert into payloads(value) values(zeroblob(?))', [(size,)]*count)
            db.commit()
            assert db.execute('pragma integrity_check').fetchone() == ('ok',)
            samples[name] = {'bytes': path.stat().st_size, 'records': count, 'payload_per_record': size,
                'logical_pages': db.execute('pragma page_count').fetchone()[0]}
        print(json.dumps({name: samples[name]}), flush=True)
    wide = output/'wide-records.sqlite'; wide.unlink(missing_ok=True)
    with closing(sqlite3.connect(wide)) as db:
        db.execute('create table wide('+','.join(f'c{index} text' for index in range(150))+')')
        db.executemany('insert into wide values('+','.join('?' for _ in range(150))+')', [('v'*10000,)*150]*3)
        db.commit()
        assert db.execute('pragma integrity_check').fetchone() == ('ok',)
        samples[wide.name] = {'bytes': wide.stat().st_size, 'records': 3, 'fields': 150, 'characters_per_value': 10000}
    many = output/'many-records.sqlite'; many.unlink(missing_ok=True)
    with closing(sqlite3.connect(many)) as db:
        db.execute('create table events(id integer primary key, value text)')
        db.executemany('insert into events values (?, ?)', ((index, f'event-{index}') for index in range(120000)))
        for index in range(130): db.execute(f'create table object_{index}(value text)')
        db.execute('create view event_view as select * from events')
        db.execute('create trigger event_trigger after insert on events begin select 1; end')
        db.commit()
        assert db.execute('pragma integrity_check').fetchone() == ('ok',)
        samples[many.name] = {'bytes': many.stat().st_size, 'records': 120000,
            'schema_entries': db.execute('select count(*) from sqlite_schema').fetchone()[0]}
    # 关闭前复制已提交且一致的 db/WAL；不依赖关闭时的 checkpoint 修改后的主文件。
    with tempfile.TemporaryDirectory(prefix='preview-switch-wal-', dir=ROOT/'_build') as temporary:
        live = Path(temporary)/'live.sqlite'
        shutil.copyfile(output/'blob-batch.sqlite', live)
        with closing(sqlite3.connect(live)) as db:
            db.execute('pragma journal_mode=WAL'); db.execute('pragma wal_autocheckpoint=0')
            db.execute('update payloads set value=zeroblob(8388608) where id=1'); db.commit()
            assert db.execute('pragma integrity_check').fetchone() == ('ok',)
            shutil.copyfile(live, output/'preview-switch.db')
            shutil.copyfile(str(live)+'-wal', output/'preview-switch.wal')
    with tempfile.TemporaryDirectory(prefix='near-wal-budget-', dir=ROOT/'_build') as temporary:
        live = Path(temporary)/'live.sqlite'
        with closing(sqlite3.connect(live)) as db:
            db.execute('pragma page_size=512'); db.execute('pragma journal_mode=WAL')
            db.execute('pragma synchronous=OFF'); db.execute('pragma wal_autocheckpoint=0')
            db.execute('create table counter(value integer)'); db.execute('insert into counter values(0)'); db.commit()
            for value in range(1, 99991):
                db.execute('update counter set value=?', (value,)); db.commit()
            assert db.execute('pragma integrity_check').fetchone() == ('ok',)
            shutil.copyfile(live, output/'near-frame-budget.db')
            shutil.copyfile(str(live)+'-wal', output/'near-frame-budget.wal')
        frames = ((output/'near-frame-budget.wal').stat().st_size-32)//536
        assert 99000 < frames < 100000
        samples['near-frame-budget'] = {'frames': frames, 'wal_bytes': (output/'near-frame-budget.wal').stat().st_size, 'value': 99990}
    (output/'scale-fixtures.json').write_text(json.dumps(samples, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(samples, ensure_ascii=False), flush=True)
    evidence = dict(database_bytes=large.stat().st_size, records=1100, logical_pages=page_count,
                    integrity_check='ok')
    (output / 'fixtures.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(evidence))


if __name__ == '__main__':
    main()
