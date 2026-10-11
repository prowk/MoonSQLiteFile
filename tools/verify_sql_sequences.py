#!/usr/bin/env python3
"""核对生成器重放一致性、物理语义和缩减失败类别保护。"""
from pathlib import Path
import hashlib
import json
import sqlite3
import tempfile

from sql_sequences import ROOT, SequenceFailure, execute, generate, preserve, reduce_operations
from reduce_fuzz import apply_mutations, failure_signature, mutations


def main():
    for original, actual in [(b'abcdef', b'aZcdXf'), (b'abcdef', b'aZc'), (b'abc', b'aZcdef')]:
        assert apply_mutations(original, mutations(original, actual)) == actual
    assert failure_signature({'kind': 'wal', 'error': 'Error: panic\n  stack'}) != failure_signature({'kind': 'wal', 'error': 'Error: timeout\n  stack'})
    plan = generate(20261011, 12)
    assert plan == generate(20261011, 12)
    with tempfile.TemporaryDirectory(prefix='sequence-regression-', dir=ROOT/'_build') as temporary:
        directory = Path(temporary)
        a = execute(plan, directory/'a')
        b = execute(plan, directory/'b')
        assert a == b and a['snapshots'] == 11 and a['records_compared'] > 0
        assert {'table_leaf', 'index_leaf', 'without_rowid', 'wal_snapshot'} <= set(a['structures'])
        # 对照错误见证由真实 SQLite 状态触发，用于测试 ddmin；不伪报库缺陷。
        signature = {'category': 'test_record_mismatch', 'object': 'items', 'witness': 'preserve-id-100000'}
        def checker(snapshot, expected, label):
            if any(row['rowid'] == '100000' for row in expected['tables'].get('items', {}).get('expected_rows', [])):
                raise SequenceFailure(signature, {'test_only': True})
            return 0
        def predicate(candidate):
            with tempfile.TemporaryDirectory(prefix='trial-', dir=directory) as trial:
                try: execute(candidate, Path(trial), checker)
                except SequenceFailure as failure: return failure.signature
                except (sqlite3.Error, AssertionError): return {'category': 'invalid_sequence'}
            return None
        assert predicate(plan) == signature
        try: execute(plan, directory/'preserve-trial', checker)
        except SequenceFailure as failure:
            saved = preserve(failure, directory/'saved')
            metadata = json.loads((saved/'failure.json').read_text(encoding='utf-8'))
            assert metadata['signature'] == signature and metadata['sqlite_version'] == sqlite3.sqlite_version
            assert (saved/'input.db').is_file() and (saved/'expected.json').is_file()
            assert '--replay' in metadata['replay']
        reduced, stats = reduce_operations(plan, signature, predicate, attempts=80, seconds=60)
        assert predicate(reduced) == signature
        assert stats['operations_after'] < stats['operations_before']
        assert any('100000' in operation.get('sql', '') for operation in reduced['operations'])
        # 普通 SQL 拒绝与记录不一致不是同一类失败，不能接受错误类别退化。
        unchanged, _ = reduce_operations(plan, signature, lambda candidate: {'category': 'parser_rejection'}, attempts=8)
        assert unchanged == plan
        print(json.dumps({'replay_deterministic': True, 'physical_oracle': a, 'reduction': stats, 'failure_signature_preserved': True}))


if __name__ == '__main__': main()
