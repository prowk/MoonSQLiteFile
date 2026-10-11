#!/usr/bin/env python3
"""评估生成 JS 的 V8 覆盖反馈；不把宿主入口次数作为核心覆盖率。"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    scripts = []
    for file in args.directory.glob('coverage-*.json'):
        for script in json.loads(file.read_text(encoding='utf-8'))['result']:
            if script['url'].replace('\\', '/').endswith('/cmd/fuzz/fuzz.js'):
                scripts.append(script)
    assert scripts, '需要实际生成核心 JS 的 V8 覆盖文件，宿主入口统计不能替代'
    functions = {}
    for script in scripts:
        for function in script['functions']:
            key = (function['functionName'], function['ranges'][0]['startOffset'])
            functions[key] = max(functions.get(key, 0), function['ranges'][0]['count'])
    source_map = ROOT/'_build/js/debug/build/cmd/fuzz/fuzz.js.map'
    source = json.loads(source_map.read_text(encoding='utf-8'))
    report = {'generated_js_functions_observed': len(functions),
              'generated_js_functions_executed': sum(count > 0 for count in functions.values()),
              'source_map_moonbit_sources': sum(name.endswith('.mbt') for name in source['sources']),
              'feasible': True, 'coverage_unit': 'generated JS function ranges, not MoonBit source branch coverage',
              'decision': 'opt-in exploration; use real structure combinations for scheduled corpus; do not add per-commit coverage threshold'}
    (ROOT/'_build/fuzz-coverage-evaluation.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(report))


if __name__ == '__main__': main()
