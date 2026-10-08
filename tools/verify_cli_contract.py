#!/usr/bin/env python3
"""用正式发布 tag 捕获的输出验证全部 CLI JSON 命令及退出码契约。"""
from pathlib import Path
import json
import subprocess
from types import SimpleNamespace

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


def verify_case(result, case):
    actual = result.stdout if case['args'] == ['summary'] else json.loads(result.stdout) if result.stdout.strip() else None
    assert result.returncode == case['exit'], (case['args'], result.returncode, result.stderr)
    assert actual == case['stdout'], f"CLI JSON 内容/字段/空值/数值类型变化：{case['args']}"
    assert shape(actual) == shape(case['stdout']), f"CLI JSON 类型变化：{case['args']}"
    assert result.stderr == case['stderr'], (case['args'], result.stderr)


def verify_baseline(version, commit):
    baseline = json.loads((ROOT/f'fixtures/cli-contract/v{version}.json').read_text(encoding='utf-8'))
    assert baseline['baseline_commit'] == commit
    commands = set()
    for case in baseline['cases']:
        result = subprocess.run(['node', 'tools/inspect.cjs', case['input'], *case['args']],
                                cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=60)
        verify_case(result, case)
        commands.add(next(value for value in case['args'] if value in {
            'header','schema','page','page-inspect','rows','records','index','scan','freelist',
            'inspect','inspect-details','tree-inspect','summary','summary-json','viewer-data','wal-inspect','wal-info'}))
    assert len(commands) == 17, commands
    print(f"Verified v{version} CLI contract: {len(baseline['cases'])} baseline cases, 17 commands")


def main():
    # 完全相等保护 JSON 内容、字段、类型、空值、错误通道及退出码。
    original = {'rowid': '9007199254740993', 'values': [None, 1], 'complete': False}
    case = {'args': ['records'], 'stdout': original, 'stderr': '', 'exit': 0}
    verify_case(SimpleNamespace(stdout=json.dumps(original), stderr='', returncode=0), case)
    for changed in [{'rowid': 9007199254740993, 'values': [None, 1], 'complete': False},
                    {'rowid': original['rowid'], 'values': [0, 1], 'complete': False},
                    {key: value for key, value in original.items() if key != 'complete'}]:
        try:
            verify_case(SimpleNamespace(stdout=json.dumps(changed), stderr='', returncode=0), case)
        except AssertionError:
            pass
        else:
            raise AssertionError('CLI 不兼容变化漏检')
    for code, stderr in [(1, ''), (0, 'changed')]:
        try:
            verify_case(SimpleNamespace(stdout=json.dumps(original), stderr=stderr, returncode=code), case)
        except AssertionError:
            pass
        else:
            raise AssertionError('CLI 退出码或错误通道变化漏检')
    for version, commit in [('0.7.0', '8a3a4c79ecd54c893604839f9136081289b8f21b'),
                            ('0.8.0', 'cf7bdc5d9c9dd808640190d7f6904be4a21de8f9')]:
        verify_baseline(version, commit)
    # 参数错误不依赖操作系统的路径错误文字，也不改变既有退出码。
    for args in [['--max-pages','0','header'],['--max-total-payload-bytes','18446744073709551616','header'],['--wal-prefix','header']]:
        result = subprocess.run(['node','tools/inspect.cjs','fixtures/core.sqlite',*args],cwd=ROOT,capture_output=True,text=True,encoding='utf-8')
        assert result.returncode == 1 and not result.stdout and result.stderr.startswith('MoonSQLiteFile:')
    print('Verified CLI argument errors and contract checker regressions')


if __name__ == '__main__':
    main()
