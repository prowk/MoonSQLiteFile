#!/usr/bin/env python3
"""在原始 corpus 与失败输入之间删除无关变异，保持同类故障。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

from sql_sequences import ROOT, reduce_operations


def failure_signature(metadata):
    # 不把正常 Invalid/Unsupported/LimitExceeded 返回当成失败；仅比较 Worker 故障。
    return {'kind': metadata.get('kind', 'db'), 'error': metadata['error'].splitlines()[0]}


def mutations(original, actual):
    changes = []
    for offset, value in enumerate(actual):
        if offset >= len(original) or value != original[offset]: changes.append({'offset': offset, 'value': value})
    if len(original) != len(actual): changes.append({'length': len(actual)})
    return changes


def apply_mutations(original, changes):
    length = next((item['length'] for item in changes if 'length' in item), len(original))
    result = bytearray(original[:length]); result.extend(b'\0'*(length-len(result)))
    for item in changes:
        if 'offset' in item and item['offset'] < length: result[item['offset']] = item['value']
    return bytes(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('failure', type=Path)
    parser.add_argument('--attempts', type=int, default=40)
    parser.add_argument('--seconds', type=int, default=120)
    args = parser.parse_args()
    assert 1 <= args.attempts <= 1000 and 1 <= args.seconds <= 1800
    path = args.failure.resolve()
    metadata = json.loads(path.with_suffix('.json').read_text(encoding='utf-8'))
    original_path = path.with_name(path.stem+'.original.sqlite')
    assert original_path.exists(), '历史失败缺少原始 corpus；请保留原始文件后再缩减，不能猜测 WAL 原始输入'
    original, actual = original_path.read_bytes(), path.read_bytes()
    signature = failure_signature(metadata)
    base = path.with_name(path.stem+'.base.sqlite') if metadata.get('kind') == 'wal' else None
    build = ROOT/'_build'; build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='byte-reduction-', dir=build) as temporary:
        trial = Path(temporary)
        def predicate(plan):
            candidate = trial/'candidate.sqlite'
            data = apply_mutations(original, plan['operations']); candidate.write_bytes(data)
            candidate.with_suffix('.json').write_text(json.dumps(metadata, ensure_ascii=False), encoding='utf-8')
            if base: candidate.with_name('candidate.base.sqlite').write_bytes(base.read_bytes())
            output = trial/'output'
            result = subprocess.run(['node', str(ROOT/'tools/fuzz.cjs'), '--replay', str(candidate), '--output', str(output)],
                                    cwd=ROOT, text=True, encoding='utf-8', capture_output=True, timeout=8)
            if result.returncode == 0: return None
            digest = hashlib.sha256(data+(base.read_bytes() if base else b'')).hexdigest()
            report = output/(digest+'.json')
            return failure_signature(json.loads(report.read_text(encoding='utf-8'))) if report.exists() else None
        plan = {'operations': mutations(original, actual)}
        assert predicate(plan) == signature, '当前构建没有重现相同故障，停止缩减'
        reduced, stats = reduce_operations(plan, signature, predicate, args.attempts, args.seconds)
        assert predicate(reduced) == signature, '最终样本未保持同类故障'
        destination = path.with_name(path.stem+'.reduced.sqlite')
        destination.write_bytes(apply_mutations(original, reduced['operations']))
        if base: destination.with_name(destination.stem+'.base.sqlite').write_bytes(base.read_bytes())
        destination.with_suffix('.json').write_text(json.dumps({**metadata, 'reduction': stats, 'original_failure': str(path)}, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        destination.with_name(destination.stem+'.original.sqlite').write_bytes(original)
        print(json.dumps({'reduced': str(destination), 'signature': signature, 'budgeted_reduction': stats,
                          'replay': f'node tools/fuzz.cjs --replay {destination}'}, ensure_ascii=False))


if __name__ == '__main__': main()
