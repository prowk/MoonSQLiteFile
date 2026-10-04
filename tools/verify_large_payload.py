#!/usr/bin/env python3
"""验收合法大 payload：默认有界失败，显式提高独立预算后完整完成。"""
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def invoke(path, options, command, expected):
    result = subprocess.run(
        ['node', str(ROOT / 'tools/inspect.cjs'), str(path), *options, *command],
        cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=120)
    assert result.returncode == expected, (command, result.returncode, result.stderr, result.stdout[:400])
    return result


def main():
    evidence = []
    with tempfile.TemporaryDirectory(prefix='payload-acceptance-', dir=ROOT / '_build') as temporary:
        path = Path(temporary) / 'large.db'
        with closing(sqlite3.connect(path)) as db:
            db.execute('create table t(v blob)')
            db.executemany('insert into t values(zeroblob(65536))', [()] * 1100)
            db.commit()
            assert db.execute('pragma integrity_check').fetchone() == ('ok',)
            assert db.execute('select sum(length(v)) from t').fetchone()[0] > 67108864
            root = str(db.execute("select rootpage from sqlite_schema where name='t'").fetchone()[0])
        failed = invoke(path, [], ['scan', root], 1)
        assert 'limit_exceeded:' in failed.stderr
        limited = json.loads(invoke(path, [], ['summary-json'], 2).stdout)
        assert limited['status'] == 'incomplete'
        budget = ['--max-total-payload-bytes', '134217728']
        scan = json.loads(invoke(path, budget, ['scan', root], 0).stdout)
        assert scan['records_read'] == 1100 and scan['completion'] == 'complete'
        assert int(scan['payload_bytes']) > 67108864
        for command in [['tree-inspect', root], ['inspect'], ['inspect-details'],
                        ['summary-json'], ['viewer-data'], ['summary']]:
            output = invoke(path, budget, command, 0).stdout
            if command[0] != 'summary':
                report = json.loads(output)
                report = report.get('inspection', report)
                assert report['status'] == 'complete', command
                if 'records_decoded' in report:
                    assert report['records_decoded'] == (1100 if command[0] == 'tree-inspect' else 1101)
            evidence.append(dict(command=command, status='complete'))
        zero = json.loads(invoke(path, ['--max-total-payload-bytes', '0'], ['tree-inspect', root], 2).stdout)
        assert zero['records_decoded'] == 0
        for value in ['-1', '1.5', '1e9', '01', '18446744073709551616', '9007199254740993x']:
            invoke(path, ['--max-total-payload-bytes', value], ['scan', root], 1)
        for value in ['9007199254740993', '18446744073709551615']:
            maximum = json.loads(invoke(path, ['--max-total-payload-bytes', value], ['scan', root, '0'], 0).stdout)
            assert maximum['records_read'] == 0
        invoke(path, budget + budget, ['scan', root], 1)
        for value in ['0', '-1', '2147483648', '2.5']:
            invoke(path, ['--max-payload-bytes', value], ['scan', root], 1)
        large_record = Path(temporary) / 'large-record.db'
        with closing(sqlite3.connect(large_record)) as db:
            db.execute('create table t(v blob)')
            db.execute('insert into t values(zeroblob(?))', (17 * 1024 * 1024,))
            db.commit()
            assert db.execute('pragma integrity_check').fetchone() == ('ok',)
        assert 'limit_exceeded:' in invoke(large_record, [], ['scan', '2'], 1).stderr
        single = json.loads(invoke(large_record, ['--max-payload-bytes', '33554432'], ['scan', '2'], 0).stdout)
        assert single['records_read'] == 1 and int(single['payload_bytes']) > 16777216
        report = dict(database_bytes=path.stat().st_size, records=1100,
                      payload_bytes=scan['payload_bytes'], default_status=limited['status'],
                      increased_budget_commands=evidence, single_payload_bytes=single['payload_bytes'],
                      uint64_decimal_validation=True)
    (ROOT / '_build/large-payload.json').write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
