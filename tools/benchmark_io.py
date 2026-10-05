#!/usr/bin/env python3
"""使用固定 SQLite 数据分别记录扫描、全局检查和 WAL 打开的读取与进程峰值内存。"""
import argparse
from contextlib import closing
import json
from pathlib import Path
import platform
import sqlite3
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def measure(path, args, launcher=None):
    result = subprocess.run(['node', str(launcher or ROOT / 'tools/inspect.cjs'), str(path),
                             '--cache-pages', '64', '--io-stats', *map(str, args)],
                            cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=120)
    if result.returncode:
        raise RuntimeError(result.stderr + result.stdout)
    output = json.loads(result.stdout)
    assert output.get('status', 'complete') == 'complete'
    if 'completion' in output:
        assert output['completion'] == 'complete'
    statistics = json.loads(result.stderr)
    return dict(reads=sum(item['reads'] for item in statistics['io']),
                bytes_read=sum(item['bytes'] for item in statistics['io']),
                max_read=max(item['maxRead'] for item in statistics['io']),
                peak_rss_bytes=statistics['peakRss'], seconds=round(statistics['seconds'], 4))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rows', default='1000,5000,20000')
    parser.add_argument('--wal-updates', default='100,1000,5000')
    parser.add_argument('--output', type=Path, default=ROOT / '_build/io-benchmark.json')
    parser.add_argument('--compare-cli', type=Path, help='同一静态输入上运行正式旧版 CLI，记录对照成本')
    args = parser.parse_args()
    counts = [int(value) for value in args.rows.split(',')]
    assert all(0 < count <= 40000 for count in counts)
    updates = [int(value) for value in args.wal_updates.split(',')]
    assert updates == sorted(set(updates)) and all(0 < count <= 50000 for count in updates)
    evidence = dict(platform=platform.platform(), python=platform.python_version(), sqlite=sqlite3.sqlite_version,
                    node=subprocess.check_output(['node', '--version'], text=True).strip(),
                           moon=subprocess.check_output(['moon', 'version', '--all'], text=True, encoding='utf-8').strip(),
                    baseline_cli=str(args.compare_cli) if args.compare_cli else None,
                    cache_pages=64, cache_block_bytes=4096, results=[])
    with tempfile.TemporaryDirectory(prefix='io-benchmark-', dir=ROOT / '_build') as temporary:
        directory = Path(temporary)
        for count in counts:
            path = directory / f'rows-{count}.db'
            with closing(sqlite3.connect(path)) as db:
                db.execute('pragma page_size=4096')
                db.execute('pragma journal_mode=wal')
                db.execute('pragma wal_autocheckpoint=0')
                db.execute('create table t(k integer primary key, x text)')
                db.execute('create index ix on t(x)')
                db.executemany('insert into t values(?,?)', [(i, f'{i:08d}' + '中' * 50) for i in range(count)])
                db.commit()
                main = directory / f'main-{count}.db'
                journal = directory / f'wal-{count}.wal'
                main.write_bytes(path.read_bytes())
                journal.write_bytes(Path(str(path) + '-wal').read_bytes())
            for action, file, command in [('scan', path, ['scan', 2]),
                                          ('inspect', path, ['summary-json']),
                                          ('wal_open', main, ['--wal', journal, 'header'])]:
                row = dict(rows=count, database_bytes=path.stat().st_size,
                           wal_bytes=journal.stat().st_size, action=action, **measure(file, command))
                if args.compare_cli:
                    row['baseline'] = measure(file, command, args.compare_cli)
                    assert all(row[key] == row['baseline'][key] for key in ['reads','bytes_read','max_read']), row
                evidence['results'].append(row)
                print(json.dumps(row, ensure_ascii=False), flush=True)
        path = directory / 'repeat.db'
        with closing(sqlite3.connect(path)) as db:
            db.execute('pragma page_size=4096')
            db.execute('pragma journal_mode=wal')
            db.execute('pragma wal_autocheckpoint=0')
            db.execute('create table t(k integer primary key, v blob)')
            db.executemany('insert into t values(?,zeroblob(128))', [(i,) for i in range(8)])
            db.commit()
            db.execute('pragma wal_checkpoint(truncate)')
            previous = 0
            for count in updates:
                for iteration in range(previous, count):
                    db.execute('update t set v=? where k in (0,1)', (bytes([(iteration + 1) % 256]) * 128,))
                    db.commit()
                previous = count
                main = directory / f'repeat-main-{count}.db'
                journal = directory / f'repeat-wal-{count}.wal'
                main.write_bytes(path.read_bytes())
                journal.write_bytes(Path(str(path) + '-wal').read_bytes())
                # 独立读取原始帧号；重复写入同一页并不会增加覆盖索引页数。
                data = journal.read_bytes()
                frame_size = 24 + struct.unpack_from('>I', data, 8)[0]
                assert (len(data) - 32) % frame_size == 0
                frames = (len(data) - 32) // frame_size
                overlay_pages = {struct.unpack_from('>I', data, offset)[0]
                                 for offset in range(32, len(data), frame_size)}
                assert frames == count and len(overlay_pages) == 1
                assert db.execute('pragma integrity_check').fetchone() == ('ok',)
                snapshot = subprocess.run(['node', str(ROOT / 'tools/inspect.cjs'), str(main),
                                           '--wal', str(journal), 'rows', 't'], cwd=ROOT,
                                          capture_output=True, text=True, encoding='utf-8', timeout=120)
                assert snapshot.returncode == 0, snapshot.stderr
                records = json.loads(snapshot.stdout)
                expected = bytes([count % 256]) * 128
                assert len(records) == 8 and bytes.fromhex(records[0]['values'][1]['value']) == expected
                statistics = measure(main, ['--wal', journal, 'header'])
                assert statistics['max_read'] <= frame_size
                row = dict(action='wal_repeated_updates', updates=count, frames=frames,
                           unique_overlay_pages=len(overlay_pages), database_bytes=main.stat().st_size,
                           wal_bytes=len(data), **statistics)
                if args.compare_cli:
                    row['baseline'] = measure(main, ['--wal', journal, 'header'], args.compare_cli)
                    assert all(row[key] == row['baseline'][key] for key in ['reads','bytes_read','max_read']), row
                evidence['results'].append(row)
                print(json.dumps(row, ensure_ascii=False), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
