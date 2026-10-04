#!/usr/bin/env python3
"""用真实 SQLite WAL 和恢复后的 SQL 查询独立核实最新已提交快照。"""
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'tools/inspect.cjs'


def cli(path, *args, code=0, text=False):
    result = subprocess.run(['node', str(CLI), str(path), *map(str, args)], cwd=ROOT,
                            capture_output=True, text=True, encoding='utf-8', timeout=30)
    assert result.returncode == code, (path.name, args, result.returncode, result.stderr)
    if not result.stdout.strip():
        assert code and result.stderr.strip()
        return None
    return result.stdout if text else json.loads(result.stdout)


def checksum(data, order, state=(0, 0)):
    a, b = state
    values = struct.unpack(order + str(len(data) // 4) + 'I', data)
    for i in range(0, len(values), 2):
        a = (a + values[i] + b) & 0xffffffff
        b = (b + values[i + 1] + a) & 0xffffffff
    return a, b


def parse(data):
    if not data:
        return {'header': None, 'frames': [], 'commits': [], 'committed_frames': 0,
                'uncommitted_frames': 0, 'database_pages': None, 'stop_reason': 'end_of_file',
                'stop_offset': 0, 'trailing_bytes': 0}
    magic, version, size, sequence, salt1, salt2, a, b = struct.unpack('>8I', data[:32])
    order = '<' if magic == 0x377f0682 else '>'
    assert checksum(data[:24], order) == (a, b)
    frames, commits, offset, reason = [], [], 32, 'end_of_file'
    while offset < len(data):
        if len(data) - offset < 24 + size:
            reason = 'truncated_frame'
            break
        page, pages, s1, s2, c1, c2 = struct.unpack('>6I', data[offset:offset + 24])
        if (s1, s2) != (salt1, salt2):
            reason = 'salt_mismatch'
            break
        if page in (0, 0xffffffff) or pages == 0xffffffff:
            reason = 'invalid_frame'
            break
        state = checksum(data[offset:offset + 8], order, (a, b))
        state = checksum(data[offset + 24:offset + 24 + size], order, state)
        if state != (c1, c2):
            reason = 'checksum_mismatch'
            break
        frames.append({'index': len(frames) + 1, 'byte_offset': offset, 'page_number': page,
                       'database_pages': pages, 'checksum1': c1, 'checksum2': c2})
        if pages:
            commits.append({'frame_index': len(frames), 'database_pages': pages})
        a, b = state
        offset += 24 + size
    committed = commits[-1]['frame_index'] if commits else 0
    return {'header': {'checksum_order': 'little_endian' if order == '<' else 'big_endian',
                      'version': version, 'page_size': size, 'checkpoint_sequence': sequence,
                      'salt1': salt1, 'salt2': salt2, 'checksum1': struct.unpack_from('>I', data, 24)[0],
                      'checksum2': struct.unpack_from('>I', data, 28)[0]},
            'frames': frames, 'commits': commits, 'committed_frames': committed,
            'uncommitted_frames': len(frames) - committed,
            'database_pages': commits[-1]['database_pages'] if commits else None,
            'stop_reason': reason, 'stop_offset': offset, 'trailing_bytes': len(data) - offset}


def endian_variant(data, order):
    if not data:
        return data
    original = parse(data)
    assert original['stop_reason'] == 'end_of_file'
    output = bytearray(data)
    struct.pack_into('>I', output, 0, 0x377f0682 if order == '<' else 0x377f0683)
    state = checksum(output[:24], order)
    struct.pack_into('>2I', output, 24, *state)
    size = original['header']['page_size']
    for frame in original['frames']:
        offset = frame['byte_offset']
        state = checksum(output[offset:offset + 8], order, state)
        state = checksum(output[offset + 24:offset + 24 + size], order, state)
        struct.pack_into('>2I', output, offset + 16, *state)
    return bytes(output)


def encoded(value):
    if value is None:
        return {'type': 'null', 'value': None}
    if isinstance(value, int):
        return {'type': 'integer', 'value': str(value)}
    if isinstance(value, bytes):
        return {'type': 'blob', 'value': value.hex()}
    if isinstance(value, str):
        return {'type': 'text', 'value': value}
    raise AssertionError(value)


def verify(directory, name, base, wal):
    case = directory / name
    case.mkdir()
    main, journal = case / 'input.db', case / 'input.wal'
    main.write_bytes(base)
    journal.write_bytes(wal)
    expected_wal = parse(wal)
    damaged = expected_wal['stop_reason'] != 'end_of_file'
    assert cli(journal, 'wal-inspect', code=1 if damaged else 0) == expected_wal
    args = ['--wal', journal]
    if damaged:
        strict = subprocess.run(['node', str(CLI), str(main), '--wal', str(journal), 'header'],
                                cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=30)
        assert strict.returncode == 1 and 'invalid:' in strict.stderr and 'UseValidPrefix' in strict.stderr, strict.stderr
        cli(main, *args, 'header', code=1)
        args.append('--wal-prefix')
    info = cli(main, *args, 'wal-info')
    assert info['wal'] == expected_wal
    # SQLite 自己恢复第二份 db/WAL；MoonBit 只读另一份原始副本，避免 oracle 改写输入。
    recovered = case / 'oracle.db'
    recovered.write_bytes(base)
    Path(str(recovered) + '-wal').write_bytes(wal)
    checked = 0
    with closing(sqlite3.connect(recovered)) as db:
        assert db.execute('PRAGMA integrity_check').fetchone() == ('ok',), name
        count = db.execute('PRAGMA page_count').fetchone()[0]
        header = cli(main, *args, 'header')
        assert header['page_count'] == count, (name, header, count)
        assert info['snapshot'] == header
        schema = db.execute('SELECT type,name,tbl_name,rootpage,sql FROM sqlite_schema ORDER BY rowid').fetchall()
        expected_schema = [dict(zip(['object_type','name','table_name','root_page','sql'], row)) for row in schema]
        assert cli(main, *args, 'schema') == expected_schema, name
        for entry in expected_schema:
            table = entry['name']
            if entry['object_type'] == 'table' and entry['root_page']:
                if table == 'keyed':
                    rows = db.execute('SELECT key,value,payload FROM keyed ORDER BY key').fetchall()
                    expected = [{'rowid': None, 'values': [encoded(v) for v in row]} for row in rows]
                else:
                    rows = db.execute(f'SELECT rowid,* FROM "{table}" ORDER BY rowid').fetchall()
                    expected = [{'rowid': str(row[0]), 'values': [encoded(None), *[encoded(v) for v in row[2:]]]} for row in rows]
                actual = cli(main, *args, 'records', table)
            elif entry['object_type'] == 'index' and table == 'value_index':
                rows = db.execute('SELECT value,id FROM items ORDER BY value,id').fetchall()
                expected = [{'rowid': None, 'values': [encoded(v) for v in row]} for row in rows]
                actual = cli(main, *args, 'index', table)
            else:
                continue
            assert [{'rowid': row['rowid'], 'values': row['values']} for row in actual] == expected, (name, table)
            checked += len(actual)
        report = cli(main, *args, 'inspect-details')
        assert report['inspection']['status'] == 'complete', (name, report)
        assert report['inspection']['ownership_complete'] and report['inspection']['ptrmap_checked']
        assert not report['inspection']['issues'] and not report['locations']
        assert len(report['inspection']['pages']) == count
        summary = cli(main, *args, 'summary', text=True)
        assert '检查状态：完整（当前结构检查范围）' in summary
    assert main.read_bytes() == base and journal.read_bytes() == wal
    print(f'Verified WAL {name}: {len(expected_wal["frames"])} valid frames, {len(expected_wal["commits"])} commits, {count} pages, {checked} records, {expected_wal["stop_reason"]}')
    return checked


def capture(dbpath):
    return dbpath.read_bytes(), Path(str(dbpath) + '-wal').read_bytes()


def scenarios(directory):
    cases = []
    for size, encoding in [(512, 'UTF-8'), (4096, 'UTF-16le'), (65536, 'UTF-16be')]:
        path = directory / f'producer-{size}.db'
        with closing(sqlite3.connect(path)) as db:
            db.execute(f'PRAGMA page_size={size}')
            db.execute(f"PRAGMA encoding='{encoding}'")
            db.execute('PRAGMA journal_mode=WAL')
            db.execute('PRAGMA wal_autocheckpoint=0')
            db.executescript('CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT,payload BLOB); CREATE INDEX value_index ON items(value); CREATE TABLE keyed(key TEXT PRIMARY KEY,value INTEGER,payload BLOB) WITHOUT ROWID;')
            cases.append((f'{size}-schema', *capture(path)))
            if size == 512:
                base, wal = capture(path)
                cases.append(('header-only', base, wal[:32]))
            for txn in range(3):
                db.executemany('INSERT INTO items VALUES(?,?,?)', [(txn * 30 + i + 1, f'{txn}-{i:03}-月🌙', bytes([i]) * (size // 2 + i * 20)) for i in range(30)])
                db.executemany('INSERT INTO keyed VALUES(?,?,?)', [(f'{txn}-{i:03}', txn * 30 + i, bytes([i]) * 80) for i in range(30)])
                db.commit()
            db.execute("UPDATE items SET value='更新月亮',payload=x'01020304' WHERE id=1")
            db.commit()
            base, wal = capture(path)
            cases.append((f'{size}-transactions', base, wal))
            cases.append((f'{size}-big-checksum', base, endian_variant(wal, '>')))
            if size == 512:
                metadata = parse(wal)
                first = metadata['commits'][-3]['frame_index']
                offset = metadata['frames'][first]['byte_offset']
                for mode, target in [('checksum', offset + 24), ('salt', offset + 8)]:
                    damaged = bytearray(wal)
                    damaged[target] ^= 1
                    cases.append((f'middle-{mode}', base, bytes(damaged)))
                damaged = bytearray(wal)
                struct.pack_into('>I', damaged, offset, 0)
                cases.append(('middle-invalid-page', base, bytes(damaged)))
            # 移除最后 commit 标记并重算，SQLite 必须保留此前值，不能暴露最后一次更新。
            pending = bytearray(wal)
            size_bytes = 24 + size
            struct.pack_into('>I', pending, len(pending) - size_bytes + 4, 0)
            pending = recalculate(bytes(pending), '<')
            cases.append((f'{size}-uncommitted', base, pending))
            cases.append((f'{size}-truncated', base, wal[:-7]))
            broken = bytearray(wal)
            broken[-1] ^= 1
            cases.append((f'{size}-checksum-tail', base, bytes(broken)))
            # 完整 checkpoint 后复用较长旧 WAL，只写少量新帧，保留旧 salt 尾部。
            assert db.execute('PRAGMA wal_checkpoint(RESTART)').fetchone()[0] == 0
            db.execute('UPDATE items SET payload=x\'abcd\' WHERE id=2')
            db.commit()
            cases.append((f'{size}-reset', *capture(path)))
    path = directory / 'resize.db'
    with closing(sqlite3.connect(path)) as db:
        db.execute('PRAGMA page_size=512')
        db.execute('PRAGMA auto_vacuum=FULL')
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('PRAGMA wal_autocheckpoint=0')
        db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT,payload BLOB)')
        db.executemany('INSERT INTO items VALUES(?,?,?)', [(i, f'{i}', b'x' * 2000) for i in range(1, 51)])
        db.commit()
        cases.append(('growth', *capture(path)))
        db.execute('DELETE FROM items')
        db.commit()
        cases.append(('shrink', *capture(path)))
        db.executemany('INSERT INTO items VALUES(?,?,?)', [(i, f'new-{i}', b'y' * 1500) for i in range(1, 21)])
        db.commit()
        cases.append(('regrowth', *capture(path)))
    return cases


def recalculate(data, order):
    output = bytearray(data)
    struct.pack_into('>I', output, 0, 0x377f0682 if order == '<' else 0x377f0683)
    state = checksum(output[:24], order)
    struct.pack_into('>2I', output, 24, *state)
    size = struct.unpack_from('>I', output, 8)[0]
    for offset in range(32, len(output), size + 24):
        state = checksum(output[offset:offset + 8], order, state)
        state = checksum(output[offset + 24:offset + 24 + size], order, state)
        struct.pack_into('>2I', output, offset + 16, *state)
    return bytes(output)


def main():
    with tempfile.TemporaryDirectory(prefix='wal-oracle-', dir=ROOT / '_build') as temporary:
        directory = Path(temporary)
        cases = scenarios(directory)
        base = (ROOT / 'fixtures/empty.sqlite').read_bytes()
        cases.append(('empty-wal', base, b''))
        total = sum(verify(directory, name, db, wal) for name, db, wal in cases)
        main = directory / 'empty-wal/input.db'
        journal = directory / 'empty-wal/input.wal'
        for options in [('wal-info',), ('--wal-prefix','header'), ('--wal',),
                        ('--wal',journal,'--wal',journal,'header'),
                        ('--wal',journal,'--wal-prefix','--wal-prefix','header'),
                        ('--wal',journal,'wal-inspect')]:
            assert cli(main, *options, code=1) is None
        bad_header = directory / 'invalid-header.wal'
        bad_header.write_bytes(bytes(32))
        assert cli(bad_header, 'wal-inspect', code=1) is None
        assert cli(main, '--wal',bad_header,'--wal-prefix','header',code=1) is None
    print(f'All WAL oracle checks passed: {len(cases)} snapshots, {total} records, both checksum byte orders, reset and resize')


if __name__ == '__main__':
    main()
