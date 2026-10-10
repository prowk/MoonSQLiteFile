// 在独立进程中验证代表性规模，记录进程峰值而不把抽样值冒充峰值。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {performance} from 'node:perf_hooks';
import {openDatabase, reportEnvelope, CancelledError} from '../_build/async-adapter/index.mjs';
import {openFileSource} from '../_build/async-adapter/node.mjs';
import core from '../_build/async-adapter/core.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixtures = path.join(root, '_build/browser-acceptance');
const cases = ['payload-default', 'payload-raised', 'records-default', 'records-raised', 'schema', 'raw-blob', 'raw-wide', 'wal-default', 'wal-limited', 'wal-cancel', 'scan-cancel'];
function clean() { assert(Object.values(core({op: 'stats'}).result).every(value => value === 0)); }
async function run(name) {
  const started = performance.now(), beforeRSS = process.memoryUsage().rss;
  const file = name.startsWith('wal-') ? 'near-frame-budget.db' : name === 'raw-blob' ? 'blob-batch.sqlite' : name === 'raw-wide' ? 'wide-records.sqlite' : name.startsWith('payload-') || name === 'scan-cancel' ? 'hundred-mib.sqlite' : 'many-records.sqlite';
  const source = await openFileSource(path.join(fixtures, file));
  const wal = name.startsWith('wal-') ? await openFileSource(path.join(fixtures, 'near-frame-budget.wal')) : null;
  const controller = new AbortController();
  let db, timer, cancelledAt, cancelMilliseconds, details = {};
  try {
    if (name === 'wal-cancel') timer = setTimeout(() => { cancelledAt = performance.now(); controller.abort(); }, 20);
    try { db = await openDatabase(source, {wal: wal ?? undefined, signal: controller.signal,
      ...(name === 'wal-limited' ? {max_frames: 99000} : {}), ...(name === 'records-raised' ? {max_rows: 200000} : {})}); }
    catch (error) {
      if (name === 'wal-limited') assert.equal(error.kind, 'limit_exceeded');
      else if (name === 'wal-cancel') { assert(error instanceof CancelledError); cancelMilliseconds = performance.now()-cancelledAt; }
      else throw error;
      details = {kind: error.kind};
    }
    if (db) {
      if (name.startsWith('payload-') || name.startsWith('records-')) {
        const result = await db.inspectDatabase(name === 'payload-raised' ? {max_total_payload_bytes: 160n*1024n*1024n} : {});
        assert.equal(result.inspection.status, name.endsWith('default') ? 'incomplete' : 'complete');
        if (name === 'payload-raised') { assert.equal(result.inspection.records_decoded, 17); assert.equal(db.header.page_count, 32804); }
        if (name === 'records-raised') assert.equal(result.inspection.records_decoded, 120133);
        if (name === 'records-default') assert.equal(result.inspection.records_decoded, 100000);
        if (name.endsWith('default')) assert(reportEnvelope(result, {scope: 'database_structure'}).diagnostics.some(item => item.category === 'budget'));
        details = {status: result.inspection.status, records: result.inspection.records_decoded, payload_bytes: result.inspection.payload_bytes, pages: db.header.page_count};
      } else if (name.startsWith('raw-')) {
        const scan = db.scan(2, {limit: 1}), record = (await scan.next()).value;
        if (name === 'raw-blob') assert.equal(record.values[1].value.length, 8388608);
        else { assert.equal(record.values.length, 150); assert(record.values.every(value => value.value.length === 10000)); }
        await scan.return(); details = {fields: record.values.length, value_characters: record.values.at(-1).value.length};
      } else if (name === 'schema') {
        const prefix = await db.schema({limit: 100}), full = await db.schema({limit: 200});
        assert.equal(prefix.entries.length, 100); assert.equal(prefix.status, 'incomplete');
        assert.equal(full.entries.length, 133); assert.equal(full.status, 'complete');
        details = {prefix: prefix.entries.length, full: full.entries.length};
      } else if (name === 'wal-default') {
        assert.equal(db.source.inspection.frames.length, 99993);
        const rows = []; const scan = await db.scanBtree(2, record => { rows.push(record); return true; });
        assert.equal(scan.status, 'complete'); assert.equal(rows.length, 1); assert.equal(String(rows[0].values[0].value), '99990');
        details = {frames: db.source.inspection.frames.length, value: rows[0].values[0].value};
      } else if (name === 'scan-cancel') {
        timer = setTimeout(() => { cancelledAt = performance.now(); controller.abort(); }, 20);
        const result = await db.scanBtree(2, () => true, {signal: controller.signal, max_total_payload_bytes: 160n*1024n*1024n});
        assert.equal(result.reason, 'cancelled'); cancelMilliseconds = performance.now()-cancelledAt;
        details = {reason: result.reason, records: result.records_read};
      } else assert.fail(`${name} 应在打开时停止`);
    }
  } finally { clearTimeout(timer); if (db) await db.close(); else await Promise.allSettled([source.close(), wal?.close()]); }
  assert(source.closed && (!wal || wal.closed)); clean();
  assert(source.statistics.maxRead <= 4096 && (!wal || wal.statistics.maxRead <= 4096));
  return {case: name, ...details, seconds: (performance.now()-started)/1000, baseline_rss_bytes: beforeRSS,
    peak_rss_bytes: process.resourceUsage().maxRSS*1024, cancellation_ms: cancelMilliseconds,
    io: {db: source.statistics, wal: wal?.statistics}, closed_handles: core({op: 'stats'}).result};
}
if (process.argv.includes('--case')) {
  const name = process.argv[process.argv.indexOf('--case')+1]; assert(cases.includes(name));
  console.log(JSON.stringify(await run(name)));
} else {
  const results = [];
  for (const name of cases) {
    const result = spawnSync(process.execPath, [fileURLToPath(import.meta.url), '--case', name], {cwd: root, encoding: 'utf8', timeout: 240000, maxBuffer: 1024*1024});
    assert.equal(result.status, 0, `${name}: ${result.stderr}\n${result.stdout}`);
    results.push(JSON.parse(result.stdout)); console.log(result.stdout.trim());
  }
  fs.writeFileSync(path.join(root, '_build/scale-acceptance.json'), JSON.stringify({platform: `${os.platform()} ${os.release()}`, node: process.version,
    memory_measurement: 'isolated process resourceUsage.maxRSS (KiB converted to bytes)', results}, null, 2)+'\n', 'utf8');
}
