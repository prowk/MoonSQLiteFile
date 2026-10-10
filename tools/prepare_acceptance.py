#!/usr/bin/env python3
"""从唯一版本配置准备本地浏览器和 TypeScript 验收依赖。"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--with-deps', action='store_true', help='Linux 上同时安装 Chromium 系统依赖')
    args = parser.parse_args()
    versions = json.loads((ROOT/'tools/toolchain.json').read_text(encoding='utf-8'))
    npm = Path(shutil.which('npm') or '')
    assert npm.is_file(), '缺少 npm'
    cli = npm.parent/'node_modules/npm/bin/npm-cli.js'
    command = ['node', str(cli)] if cli.is_file() else [str(npm)]
    for directory, name in [('browser-tools', 'playwright'), ('type-tools', 'typescript')]:
        subprocess.run([*command, 'install', '--prefix', str(ROOT/'_build'/directory), '--no-audit',
                        '--no-fund', '--ignore-scripts', name+'@'+versions[name]], cwd=ROOT, check=True)
    subprocess.run(['node', str(ROOT/'_build/browser-tools/node_modules/playwright/cli.js'),
                    'install', *(['--with-deps'] if args.with_deps else []), 'chromium'], cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
