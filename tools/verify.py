#!/usr/bin/env python3
"""跨平台执行完整项目验收；CI 和本地提交前检查共用此入口。"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]

# 依赖顺序只在此维护；单项脚本仍可用于开发反馈。
CHECKS = (
    ('python', 'tools/verify_toolchain.py'),
    ('moon', 'check', '--target', 'all', '--deny-warn'),
    ('moon', 'build', '--target', 'all', '--deny-warn'),
    ('moon', 'test', '--target', 'all', '--deny-warn'),
    ('moon', 'fmt', '--check'),
    ('python', 'tools/verify_api.py'),
    ('python', 'tools/verify_layout.py'),
    ('python', 'tools/verify_cli_contract.py'),
    ('python', 'tools/generate_fixtures.py', '--check'),
    ('python', 'tools/verify_oracle.py'),
    ('python', 'tools/generate_btree_fixtures.py', '--check'),
    ('python', 'tools/verify_btree_oracle.py'),
    ('python', 'tools/verify_inspection.py'),
    ('python', 'tools/verify_wal_oracle.py'),
    ('python', 'tools/verify_review.py'),
    ('node', 'tools/verify_range_io.cjs'),
    ('node', 'tools/verify_wide_wal.cjs'),
    ('python', 'tools/verify_large_payload.py'),
    ('python', 'tools/benchmark_io.py'),
    ('python', 'tools/benchmark_compatibility.py'),
    ('moon', 'run', '--target', 'js', 'src/examples/basic'),
    ('python', 'tools/verify_consumer.py'),
    ('python', 'tools/build_viewer.py'),
    ('node', 'tools/verify_viewer.cjs'),
    ('python', 'tools/build_async.py'),
    ('node', 'tools/verify_async_api.mjs'),
    ('python', 'tools/verify_examples.py'),
    ('node', 'tools/verify_async.mjs'),
    ('python', 'tools/verify_async_package.py'),
    ('python', 'tools/verify_async_wal.py'),
    ('python', 'tools/generate_browser_fixtures.py'),
    ('node', 'tools/verify_browser.cjs'),
    ('python', 'tools/verify_regressions.py'),
    ('node', 'tools/fuzz.cjs', '--seed', '20261003', '--iterations', '512'),
    ('python', 'tools/verify_release.py'),
    ('python', 'tools/verify_maintenance.py'),
)


def content_hashes(root):
    # 忽略构建产物，用 Git 的文件清单记录实际验收内容，包括尚未提交的新增文件。
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard'],
                                    cwd=root, text=True, encoding='utf-8').splitlines()
    return {name: hashlib.sha256((root/name).read_bytes()).hexdigest()
            for name in sorted(set(names)) if (root/name).is_file()}


def run_checks(commands, root, output, env):
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for index, command in enumerate(commands, 1):
        label = shlex.join(command)
        print(f'[{index}/{len(commands)}] {label}', flush=True)
        executable = sys.executable if command[0] == 'python' else shutil.which(command[0])
        log = output/f'{index:02d}.log'
        start = time.monotonic()
        with log.open('w', encoding='utf-8') as stream:
            try:
                if not executable:
                    raise FileNotFoundError(f'找不到工具：{command[0]}')
                result = subprocess.run([executable, *command[1:]], cwd=root, env=env,
                                        stdout=stream, stderr=subprocess.STDOUT, timeout=1800)
                code = result.returncode
            except (OSError, subprocess.TimeoutExpired) as error:
                stream.write(str(error)+'\n')
                code = 1
        results.append({'command': list(command), 'exit_code': code,
                        'seconds': round(time.monotonic()-start, 3), 'log': log.name})
        (output/'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        print(f'  {"PASS" if code == 0 else "FAIL"} ({results[-1]["seconds"]}s)', flush=True)
        if code:
            print(log.read_text(encoding='utf-8'), flush=True)
            print(f'停止验收，后续 {len(commands)-index} 项未执行；日志：{output}', flush=True)
            return 1
    return 0


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='保存逐项日志与内容摘要的目录')
    args = parser.parse_args()
    channel = os.environ.get('MOONSQLITE_TOOLCHAIN_CHANNEL', 'pinned')
    output = args.output or ROOT/'_build/verification'/channel
    before = content_hashes(ROOT)
    output.mkdir(parents=True, exist_ok=True)
    (output/'content-hashes.json').write_text(json.dumps(before, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    env = dict(os.environ, PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
    browser_tools = ROOT/'_build/browser-tools/node_modules/playwright'
    if browser_tools.is_dir():
        env.setdefault('MOONSQLITE_PLAYWRIGHT', str(browser_tools))
    code = run_checks(CHECKS, ROOT, output, env)
    if before != content_hashes(ROOT):
        print('验收期间源码发生变化，必须重新验证最终内容', flush=True)
        code = 1
    summary = {'channel': channel, 'passed': code == 0, 'required_checks': len(CHECKS),
               'content_hashes': 'content-hashes.json', 'results': 'results.json'}
    (output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n', encoding='utf-8')
    if not code:
        print(f'完整验收通过：{len(CHECKS)} 项，{channel} 通道；日志：{output}', flush=True)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
