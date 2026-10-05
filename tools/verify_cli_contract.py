#!/usr/bin/env python3
"""用正式 v0.7.0 tag 捕获的输出验证全部 CLI JSON 命令及退出码契约。"""
from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def shape(value):
    if isinstance(value,dict):
        return {key:shape(item) for key,item in value.items()}
    if isinstance(value,list):
        return [shape(item) for item in value]
    if isinstance(value,bool):
        return 'boolean'
    if isinstance(value,(int,float)):
        return 'number'
    return type(value).__name__


def main():
    baseline = json.loads((ROOT/'fixtures/cli-contract/v0.7.0.json').read_text(encoding='utf-8'))
    assert baseline['baseline_commit'] == '8a3a4c79ecd54c893604839f9136081289b8f21b'
    commands = set()
    for case in baseline['cases']:
        result = subprocess.run(['node', 'tools/inspect.cjs', case['input'], *case['args']],
                                cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=60)
        actual = result.stdout if case['args'] == ['summary'] else json.loads(result.stdout) if result.stdout.strip() else None
        assert result.returncode == case['exit'], (case['args'], result.returncode, result.stderr)
        assert actual == case['stdout'], f"CLI JSON 内容/字段/空值/数值类型变化：{case['args']}"
        assert shape(actual) == shape(case['stdout']), f"CLI JSON 类型变化：{case['args']}"
        assert result.stderr == case['stderr'], (case['args'], result.stderr)
        commands.add(next(value for value in case['args'] if value in {
            'header','schema','page','page-inspect','rows','records','index','scan','freelist',
            'inspect','inspect-details','tree-inspect','summary','summary-json','viewer-data','wal-inspect','wal-info'}))
    assert len(commands) == 17, commands
    # 参数错误不依赖操作系统的路径错误文字，也不改变既有退出码。
    for args in [['--max-pages','0','header'],['--max-total-payload-bytes','18446744073709551616','header'],['--wal-prefix','header']]:
        result = subprocess.run(['node','tools/inspect.cjs','fixtures/core.sqlite',*args],cwd=ROOT,capture_output=True,text=True,encoding='utf-8')
        assert result.returncode == 1 and not result.stdout and result.stderr.startswith('MoonSQLiteFile:')
    print(f"Verified CLI contract: {len(baseline['cases'])} baseline cases, 17 commands, argument errors")


if __name__ == '__main__':
    main()
