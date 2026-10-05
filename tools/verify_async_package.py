#!/usr/bin/env python3
"""使用实际 npm tarball 在独立消费目录验证包导出，无网络或发布操作。"""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(command, cwd):
    result = subprocess.run(command, cwd=cwd, check=True, capture_output=True,
                            text=True, encoding='utf-8', timeout=60)
    return result.stdout


def main():
    npm = Path(shutil.which('npm') or '')
    if not npm.is_file():
        raise SystemExit('缺少 npm')
    npm_cli = npm.parent / 'node_modules/npm/bin/npm-cli.js'
    npm_command = ['node', str(npm_cli)] if npm_cli.exists() else [str(npm)]
    cache = str(ROOT / '_build/npm-cache')
    with tempfile.TemporaryDirectory(prefix='async-consumer-', dir=ROOT / '_build') as temporary:
        consumer = Path(temporary)
        packed = json.loads(run([*npm_command, 'pack', str(ROOT / '_build/async-adapter'),
                                '--pack-destination', str(consumer), '--ignore-scripts',
                                '--offline', '--cache', cache, '--json'], ROOT))
        filenames = {entry['path'] for entry in packed[0]['files']}
        assert {'package.json', 'core.mjs', 'index.mjs', 'node.mjs', 'LICENSE', 'README.md'} <= filenames
        assert not {'example.mjs', 'node_modules', 'fixtures'} & filenames
        (consumer / 'package.json').write_text('{"private":true,"type":"module"}\n', encoding='utf-8')
        run([*npm_command, 'install', str(consumer / packed[0]['filename']), '--offline',
             '--ignore-scripts', '--no-audit', '--no-fund', '--cache', cache], consumer)
        source = '''// 消费独立打包结果，不从源码目录或内部 core 入口导入。
import assert from 'node:assert/strict';
import {openDatabase, BlobSource} from '@prowk/moonsqlitefile-async';
import {openFileSource} from '@prowk/moonsqlitefile-async/node';
const db = await openDatabase(await openFileSource(process.argv[2]));
try {
  const schema = await db.schema(); assert.equal(schema.status, 'complete');
  const report = await db.inspectDatabase(); assert.equal(report.inspection.status, 'complete');
  assert.equal(report.header.page_count, 96);
  const result = await db.scanBtree(2, () => true); assert.equal(result.records_read, 6);
} finally { await db.close(); }
assert.equal(typeof BlobSource, 'function');
console.log('Independent npm tarball exports, Node source and core inspection passed');
'''
        (consumer / 'main.mjs').write_text(source, encoding='utf-8')
        print(run(['node', 'main.mjs', str(ROOT / 'fixtures/core.sqlite')], consumer).strip())


if __name__ == '__main__':
    main()
