#!/usr/bin/env python3
"""复用 SQLite 物理记录 oracle，生成、重放及缩减有界 SQL 操作序列。"""
from __future__ import annotations

import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import random
import shutil
import sqlite3
import subprocess
import tempfile
import time

from generate_btree_fixtures import collect_btree_oracle
from verify_oracle import run_cli
from verify_wal_oracle import parse as parse_wal

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT/'_build/fuzz-failures/sql'


class SequenceFailure(Exception):
    def __init__(self, signature, details):
        super().__init__(json.dumps(signature, ensure_ascii=False))
        self.signature, self.details = signature, details


def literal(value):
    return "'"+value.replace("'", "''")+"'"


def generate(seed, rows=80):
    rng = random.Random(seed)
    size = rng.choice([512, 1024, 4096, 65536])
    encoding = rng.choice(['UTF-8', 'UTF-16le', 'UTF-16be'])
    operations = []
    def sql(text): operations.append({'sql': text})
    def snapshot(label): operations.append({'snapshot': label})
    sql(f'PRAGMA page_size={size}')
    sql(f'PRAGMA encoding={literal(encoding)}')
    sql(f'PRAGMA auto_vacuum={rng.choice([0, 1, 2])}')
    sql('CREATE TABLE items(id INTEGER PRIMARY KEY, value, note TEXT, payload BLOB)')
    sql('CREATE TABLE keyed(value TEXT, ordinal INTEGER, key TEXT, payload BLOB, PRIMARY KEY(key COLLATE NOCASE DESC,ordinal)) WITHOUT ROWID')
    sql('CREATE INDEX item_note ON items(note COLLATE NOCASE DESC,value)')
    sql('CREATE INDEX keyed_value ON keyed(value,ordinal DESC)')
    sql('BEGIN IMMEDIATE')
    for n in range(rows):
        rowid = n-rows//2
        text = literal(f'{n:04d}-'+rng.choice(['中文🌙', 'abc', "quote'", '']))
        value = rng.choice(['NULL', '-9223372036854775808', '9223372036854775807', '1.25', text])
        length = rng.choice([0, 7, 127, 512, 4096, 9000])
        payload = "X'"+bytes([rng.randrange(256)]) .hex()*length+"'"
        sql(f'INSERT INTO items VALUES({rowid},{value},{text},{payload})')
        sql(f'INSERT INTO keyed VALUES({text},{n},{literal(f"key-{n%11:02d}")},{payload})')
    sql('COMMIT'); snapshot('inserted')
    sql('BEGIN'); sql('UPDATE items SET note=note||\'rolled-back\'')
    sql('SAVEPOINT nested'); sql('DELETE FROM keyed WHERE ordinal%3=0')
    sql('ROLLBACK TO nested'); sql('RELEASE nested'); sql('ROLLBACK')
    sql('BEGIN')
    sql('DELETE FROM items WHERE id%3=0')
    sql('UPDATE items SET payload=zeroblob(8193),note=note||\'changed\' WHERE id%7=0')
    sql('DELETE FROM keyed WHERE ordinal%4=0')
    sql('UPDATE keyed SET value=value||\'updated\' WHERE ordinal%5=0')
    sql('COMMIT'); snapshot('deleted_updated')
    # 真实释放并复用页面，再核对 VACUUM 后的重排。
    sql('CREATE TABLE scratch(data BLOB)')
    sql('INSERT INTO scratch VALUES(zeroblob(32769))'); sql('DROP TABLE scratch'); snapshot('released_pages')
    sql('CREATE TABLE reused(id INTEGER PRIMARY KEY,data BLOB)')
    sql('INSERT INTO reused VALUES(1,zeroblob(20001))'); snapshot('page_reuse')
    sql('VACUUM'); snapshot('vacuum')
    sql('PRAGMA journal_mode=WAL'); sql('PRAGMA wal_autocheckpoint=0')
    for phase, mode in enumerate(['PASSIVE', 'RESTART', 'TRUNCATE']):
        sql('BEGIN IMMEDIATE')
        sql(f'UPDATE items SET note=note||{literal(f"wal-{phase}")} WHERE id%2={phase%2}')
        sql(f'INSERT INTO items VALUES({100000+phase},NULL,{literal(f"wal-{phase}")},zeroblob({513+phase*2048}))')
        sql('COMMIT'); snapshot(f'wal_{phase}')
        sql(f'PRAGMA wal_checkpoint({mode})'); snapshot(f'checkpoint_{mode.lower()}')
    return {'format': 'moonsqlitefile-sql-sequence', 'format_version': 1, 'seed': seed,
            'sqlite_version': sqlite3.sqlite_version, 'rows': rows, 'operations': operations}


def overlay(base, wal):
    if not wal: return base
    report = parse_wal(wal)
    # RESTART 后的旧 salt/checksum 尾部不属于当前有效日志；复用已提交有效前缀契约。
    assert report['stop_reason'] in ['end_of_file', 'salt_mismatch', 'checksum_mismatch']
    if not report['committed_frames']: return base
    size = report['header']['page_size']
    result = bytearray(base[:report['database_pages']*size])
    result.extend(b'\0'*(report['database_pages']*size-len(result)))
    for frame in report['frames'][:report['committed_frames']]:
        if frame['page_number'] <= report['database_pages']:
            start = (frame['page_number']-1)*size
            offset = frame['byte_offset']+24
            result[start:start+size] = wal[offset:offset+size]
    return bytes(result)


def compare(snapshot, expected, label):
    options = ['--wal', snapshot/'input.wal'] if (snapshot/'input.wal').exists() else []
    if options and parse_wal((snapshot/'input.wal').read_bytes())['stop_reason'] != 'end_of_file': options.append('--wal-prefix')
    for group, command in [('tables', 'records'), ('indexes', 'index')]:
        for name, table in expected[group].items():
            try: actual = run_cli(snapshot/'input.db', *options, command, name)
            except (AssertionError, subprocess.TimeoutExpired) as error:
                cause = str(error).replace(str(snapshot), '<snapshot>')
                raise SequenceFailure({'category': 'parser_rejection', 'snapshot': label, 'object': name, 'cause': cause}, {'error': str(error)}) from error
            actual = [{'rowid': row['rowid'], 'values': row['values']} for row in actual]
            reference = table['expected_rows']
            if actual != reference:
                index = next((i for i, pair in enumerate(zip(actual, reference)) if pair[0] != pair[1]), min(len(actual), len(reference)))
                wanted = reference[index] if index < len(reference) else None
                obtained = actual[index] if index < len(actual) else None
                # 缩减必须保留同一个物理记录差异，不能降级成一般拒绝。
                witness = hashlib.sha256(json.dumps([wanted, obtained], sort_keys=True, ensure_ascii=False).encode('utf-8')).hexdigest()
                raise SequenceFailure({'category': 'record_mismatch', 'snapshot': label, 'object': name, 'witness': witness},
                                      {'index': index, 'expected': wanted, 'actual': obtained})
    try: inspection = run_cli(snapshot/'input.db', *options, 'inspect')
    except (AssertionError, subprocess.TimeoutExpired) as error:
        raise SequenceFailure({'category': 'inspection_rejection', 'snapshot': label, 'cause': str(error).replace(str(snapshot), '<snapshot>')}, {'error': str(error)}) from error
    if inspection['status'] != 'complete':
        raise SequenceFailure({'category': 'inspection_status', 'snapshot': label, 'status': inspection['status']}, inspection)
    return sum(len(table['expected_rows']) for group in ['tables', 'indexes'] for table in expected[group].values())


def execute(plan, directory, checker=compare, deadline=None):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory/'working.db'
    snapshots, records, structures = 0, 0, set()
    with closing(sqlite3.connect(path, isolation_level=None)) as db:
        for index, operation in enumerate(plan['operations']):
            if deadline is not None and time.monotonic() > deadline: raise TimeoutError('SQL 序列时间预算耗尽')
            if 'sql' in operation:
                cursor = db.execute(operation['sql']); cursor.fetchall()
                continue
            assert not db.in_transaction, '只在已提交边界保存一致 db/WAL'
            snapshot = directory/'snapshot'
            snapshot.mkdir(exist_ok=True)
            base = path.read_bytes()
            wal_path = path.with_name(path.name+'-wal')
            wal = wal_path.read_bytes() if wal_path.exists() else b''
            (snapshot/'input.db').write_bytes(base)
            if wal: (snapshot/'input.wal').write_bytes(wal)
            elif (snapshot/'input.wal').exists(): (snapshot/'input.wal').unlink()
            image = overlay(base, wal)
            expected = collect_btree_oracle(db, image)
            assert expected['integrity_check'] == 'ok'
            kinds = {2: 'index_interior', 5: 'table_interior', 10: 'index_leaf', 13: 'table_leaf'}
            for group in ['tables', 'indexes']:
                for tree in expected[group].values():
                    structures.update(kinds[page['kind']] for page in tree['tree']['pages'])
                    for row in tree['expected_rows']:
                        if any(value['type'] == 'blob' and len(value['value'])//2 > expected['page_size'] for value in row['values']):
                            structures.add('overflow_payload')
            if int.from_bytes(image[36:40], 'big'): structures.add('freelist_nonempty')
            (snapshot/'expected.json').write_text(json.dumps(expected, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
            # SQLite dbstat 提供实际结构反馈；仅报告结构特征，不冒充代码覆盖率。
            try:
                for kind, count, payload, maximum in db.execute('SELECT pagetype,ncell,payload,mx_payload FROM dbstat'):
                    structures.add('sqlite_'+kind)
                    if maximum > db.execute('PRAGMA page_size').fetchone()[0]: structures.add('overflow_payload')
            except sqlite3.OperationalError: structures.add('dbstat_unavailable')
            if wal: structures.add('wal_snapshot')
            if expected['tables'] and any(item['without_rowid'] for item in expected['tables'].values()): structures.add('without_rowid')
            try: records += checker(snapshot, expected, operation['snapshot'])
            except SequenceFailure as failure:
                failure.plan = {**plan, 'operations': plan['operations'][:index+1]}
                failure.snapshot = snapshot
                raise
            snapshots += 1
    return {'snapshots': snapshots, 'records_compared': records, 'structures': sorted(structures)}


def preserve(failure, destination=OUTPUT):
    digest = hashlib.sha256(json.dumps(failure.plan, sort_keys=True, ensure_ascii=False).encode('utf-8')).hexdigest()[:16]
    directory = destination/digest
    directory.mkdir(parents=True, exist_ok=True)
    for name in ['input.db', 'input.wal', 'expected.json']:
        if (failure.snapshot/name).exists(): shutil.copyfile(failure.snapshot/name, directory/name)
    (directory/'sequence.json').write_text(json.dumps(failure.plan, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    metadata = {'signature': failure.signature, 'details': failure.details, 'seed': failure.plan['seed'],
                'sqlite_version': sqlite3.sqlite_version, 'replay': f'python tools/sql_sequences.py --replay {directory.relative_to(ROOT).as_posix()}/sequence.json'}
    (directory/'failure.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    return directory


def reduce_operations(plan, signature, predicate, attempts=80, seconds=120):
    """有界 ddmin，保留失败类别、对象、快照和记录差异见证。"""
    best, count, granularity = list(plan['operations']), 0, 2
    deadline = time.monotonic()+seconds
    while len(best) >= 2 and count < attempts and time.monotonic() < deadline:
        width = (len(best)+granularity-1)//granularity
        changed = False
        for start in range(0, len(best), width):
            if count >= attempts or time.monotonic() >= deadline: break
            candidate = best[:start]+best[start+width:]
            count += 1
            if predicate({**plan, 'operations': candidate}) == signature:
                best, changed = candidate, True
                granularity = max(2, granularity-1)
                break
        if not changed:
            if granularity >= len(best): break
            granularity = min(len(best), granularity*2)
    return {**plan, 'operations': best}, {'attempts': count, 'operations_before': len(plan['operations']), 'operations_after': len(best)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', type=int, default=20261011)
    parser.add_argument('--cases', type=int, default=4)
    parser.add_argument('--rows', type=int, default=80)
    parser.add_argument('--seconds', type=int, default=300)
    parser.add_argument('--replay', type=Path)
    parser.add_argument('--reduce', type=Path)
    args = parser.parse_args()
    assert 1 <= args.cases <= 1000 and 8 <= args.rows <= 1000 and 1 <= args.seconds <= 1800
    directory = ROOT/'_build/sql-sequences'; directory.mkdir(parents=True, exist_ok=True)
    deadline, results = time.monotonic()+args.seconds, []
    source = args.replay or args.reduce
    plans = [json.loads(source.read_text(encoding='utf-8'))] if source else [generate(args.seed+n, args.rows) for n in range(args.cases)]
    for plan in plans:
        with tempfile.TemporaryDirectory(prefix='sequence-', dir=directory) as temporary:
            try: results.append(execute(plan, Path(temporary), deadline=deadline))
            except SequenceFailure as failure:
                saved = preserve(failure)
                if args.reduce:
                    def predicate(candidate):
                        with tempfile.TemporaryDirectory(prefix='reduce-', dir=directory) as trial:
                            try: execute(candidate, Path(trial), deadline=deadline)
                            except SequenceFailure as same: return same.signature
                            except (sqlite3.Error, AssertionError, TimeoutError): pass
                        return None
                    reduced, stats = reduce_operations(failure.plan, failure.signature, predicate, seconds=max(1, int(deadline-time.monotonic())))
                    with tempfile.TemporaryDirectory(prefix='minimal-', dir=directory) as trial:
                        try: execute(reduced, Path(trial))
                        except SequenceFailure as minimal:
                            assert minimal.signature == failure.signature
                            saved = preserve(minimal)
                            (saved/'reduction.json').write_text(json.dumps(stats, indent=2)+'\n', encoding='utf-8')
                raise SystemExit(f'SQL sequence failure preserved: {saved}\nReplay: python tools/sql_sequences.py --replay {saved.relative_to(ROOT).as_posix()}/sequence.json')
    report = {'seed': args.seed, 'sqlite_version': sqlite3.sqlite_version, 'cases': len(results), 'results': results}
    (directory/'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__': main()
