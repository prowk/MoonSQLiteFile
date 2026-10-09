#!/usr/bin/env python3
"""使用实际 npm tarball 在独立消费目录验证包导出，无网络或发布操作。"""
import json
import os
from pathlib import Path
import shutil
import sqlite3
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
        assert {'package.json', 'core.mjs', 'index.mjs', 'node.mjs', 'index.d.ts', 'node.d.ts', 'LICENSE', 'README.md', 'example-node.mjs', 'example-browser.mjs'} <= filenames
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
        installed = consumer/'node_modules/@prowk/moonsqlitefile-async'
        example = '''import assert from 'node:assert/strict';
import {previewFiles} from './node_modules/@prowk/moonsqlitefile-async/example-node.mjs';
const result = await previewFiles(process.argv[2]);
assert.equal(result.schema.status, 'complete'); assert.equal(result.rows.length, 3);
console.log('Installed Node example passed');
'''
        (consumer/'example.mjs').write_text(example, encoding='utf-8')
        print(run(['node', 'example.mjs', str(ROOT/'fixtures/core.sqlite')], consumer).strip())
        # 直接运行独立消费项目的实际源码，而不是重新维护一份近似示例。
        shutil.copyfile(ROOT/'examples/async-consumer/main.mjs', consumer/'consumer-main.mjs')
        result = json.loads(run(['node', 'consumer-main.mjs', str(ROOT/'fixtures/core.sqlite')], consumer))
        assert result['schema']['status'] == 'complete' and len(result['records']) == 3
        live = consumer/'live.sqlite'
        connection = sqlite3.connect(live)
        try:
            connection.execute('PRAGMA page_size=512')
            connection.execute('PRAGMA journal_mode=WAL')
            connection.execute('PRAGMA wal_autocheckpoint=0')
            connection.execute('CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT)')
            connection.executemany('INSERT INTO records VALUES (?, ?)', [(index, 'record') for index in range(6)])
            connection.commit()
            shutil.copyfile(live, consumer/'copy.sqlite')
            shutil.copyfile(str(live)+'-wal', consumer/'copy.wal')
        finally:
            connection.close()
        result = json.loads(run(['node', 'consumer-main.mjs', 'copy.sqlite', 'copy.wal'], consumer))
        assert len(result['records']) == 3 and result['preview']['partial']
        assert any(item['category'] == 'budget' for item in result['preview']['diagnostics'])
        print('Independent consumer project: installed package, WAL, records and partial report passed')
        compiler = Path(os.environ.get('MOONSQLITE_TYPESCRIPT', str(ROOT/'_build/type-tools/node_modules/typescript')))
        pinned = json.loads((ROOT/'tools/toolchain.json').read_text(encoding='utf-8'))['typescript']
        assert json.loads((compiler/'package.json').read_text(encoding='utf-8'))['version'] == pinned
        source = '''import {openDatabase, BlobSource, errorInfo, reportEnvelope, type Decimal} from '@prowk/moonsqlitefile-async';
import {openFileSource} from '@prowk/moonsqlitefile-async/node';
const db = await openDatabase(await openFileSource('copy.sqlite'), {wal: await openFileSource('copy.wal'), closeSources: false});
try {
  const schema = await db.schema();
  for await (const row of db.scan(1, {limit: 2, max_total_payload_bytes: 100n})) {
    const id: Decimal | null = row.rowid; console.log(id, row.values[0]?.type); break;
  }
  const report = reportEnvelope(await db.inspectDatabase(), {scope: 'database_structure'});
  const status: 'complete' | 'failed' | 'incomplete' = report.status; console.log(status, schema.entries[0]?.object_type);
  await openDatabase(new BlobSource(new Blob()), {signal: new AbortController().signal});
  console.log(errorInfo(new Error()).category);
  // @ts-expect-error 偏移必须为 bigint。
  await db.source.read(1, 2);
  // @ts-expect-error 根页必须为 number。
  db.scan('1');
  // @ts-expect-error 累计预算不能为可能丢失精度的 number。
  db.scan(1, {max_total_payload_bytes: 100});
  // @ts-expect-error 不接受没有源契约的对象。
  await openDatabase({size: 1});
} finally { await db.close(); }
'''
        (consumer/'consumer.ts').write_text(source, encoding='utf-8')
        for module, resolution in [('NodeNext', 'NodeNext'), ('ESNext', 'Bundler')]:
            run(['node', str(compiler/'bin/tsc'), '--noEmit', '--strict', '--target', 'ES2022',
                 '--module', module, '--moduleResolution', resolution, 'consumer.ts'], consumer)
        print('Installed package types passed strict NodeNext/Bundler and invalid-call checks')
        print(run(['node', str(ROOT/'tools/verify_package_browser.cjs'), str(installed)], ROOT).strip())


if __name__ == '__main__':
    main()
