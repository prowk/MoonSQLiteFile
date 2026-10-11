// 每种模式在独立进程读取同一文件；峰值来自进程高水位，包含核心与桥接实际分配。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {performance} from 'node:perf_hooks';
import {openDatabase, CancelledError} from '../_build/async-adapter/index.mjs';
import {openFileSource} from '../_build/async-adapter/node.mjs';

if (process.argv[2] === '--child') {
  const [file, mode] = process.argv.slice(3), source = await openFileSource(file);
  const db = await openDatabase(source, {cachePages: 1});
  const before = {...source.statistics}, started = performance.now(); let count = 0, copied = 0;
  const scan = mode === 'full' ? db.scan(2) : db.scanProjected(2, {fields: file.includes('wide') ? [0] : [1], max_field_bytes: 256});
  for await (const record of scan) { count++; if (mode !== 'full') copied += Number(record.copied_bytes); }
  const result = {file, mode, count, seconds: (performance.now() - started) / 1000,
    bytes: source.statistics.bytes - before.bytes, reads: source.statistics.reads - before.reads,
    copied_bytes: mode === 'full' ? Number(scan.result.payload_bytes) : copied,
    peak_rss_bytes: process.resourceUsage().maxRSS * 1024};
  await db.close(); console.log(JSON.stringify(result));
} else {
  const results = [];
  for (const file of ['blob-batch.sqlite', 'wide-records.sqlite']) {
    const pair = [];
    for (const mode of ['full', 'projected']) {
      const child = spawnSync(process.execPath, [fileURLToPath(import.meta.url), '--child', `_build/browser-acceptance/${file}`, mode], {encoding: 'utf8', timeout: 180000});
      assert.equal(child.status, 0, child.stderr); const result = JSON.parse(child.stdout); pair.push(result); results.push(result);
      console.log(JSON.stringify(result));
    }
    assert.equal(pair[0].count, pair[1].count);
    assert(pair[1].bytes < pair[0].bytes / 10, '所选前部字段应实际减少核心读取量');
    assert(pair[1].copied_bytes < pair[0].copied_bytes / 100);
  }
  const source = await openFileSource('_build/browser-acceptance/hundred-mib.sqlite'), db = await openDatabase(source, {cachePages: 1});
  const scan = db.scanProjected(2, {fields: [1], max_field_bytes: 16}); const record = (await scan.next()).value; await scan.return();
  const controller = new AbortController(), started = performance.now();
  const reading = db.readBlobChunk(record, 1, {offset: 8388600, length: 8, signal: controller.signal});
  const timer = setTimeout(() => controller.abort(), 5);
  try { await assert.rejects(reading, CancelledError); } finally { clearTimeout(timer); await db.close(); }
  const cancellation_ms = performance.now() - started; assert(cancellation_ms < 10000);
  const evidence = {measurement: 'isolated Node processes; process.resourceUsage().maxRSS; I/O excludes open; no Worker transport',
    results, cancellation_ms};
  fs.writeFileSync('_build/field-read-benchmark.json', JSON.stringify(evidence, null, 2) + '\n', 'utf8');
  console.log(JSON.stringify({cancellation_ms}));
}
