// 同步 CLI 已由 SQLite 独立对照验证；此处核对异步结果及宿主生命周期。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {openDatabase, BlobSource, CachedSource, SourceError, readExact, CancelledError} from '../_build/async-adapter/index.mjs';
import {openFileSource} from '../_build/async-adapter/node.mjs';
import core from '../_build/async-adapter/core.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
process.chdir(root);
const sleep = ms => new Promise(done => setTimeout(done, ms));
function cli(file, args, command) {
  const result = spawnSync(process.execPath, ['tools/inspect.cjs', file, ...args, ...command], {encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
  assert([0, 1, 2].includes(result.status), result.stderr);
  assert(result.stdout.trim(), result.stderr);
  return JSON.parse(result.stdout);
}
function clean() {
  assert.deepEqual(core({op: 'stats'}).result, {contexts: 0, scans: 0, inspections: 0, wals: 0, indexes: 0});
}
async function walLifecycle(file, wal, metadata) {
  const baseBytes = new Uint8Array(fs.readFileSync(file)), walBytes = new Uint8Array(fs.readFileSync(wal));
  if (walBytes.length < 4096) return;
  const controller = new AbortController(), base = memory(baseBytes), source = memory(walBytes);
  await assert.rejects(openDatabase(base, {wal: source, signal: controller.signal,
    onProgress: progress => { if (progress.frames_read >= (metadata.frames > 2 ? 2 : 0)) controller.abort(); }}), CancelledError);
  assert(base.closed && source.closed); clean();
  const limited = memory(baseBytes), limitedWal = memory(walBytes);
  if (metadata.frames > 1 || (metadata.frames === 1 && metadata.stop_reason !== 'end_of_file')) {
    await assert.rejects(openDatabase(limited, {wal: limitedWal, max_frames: 1}), error => error.kind === 'limit_exceeded');
  } else {
    const one = await openDatabase(limited, {wal: limitedWal, max_frames: 1, tailPolicy: 'valid_prefix'});
    await one.close();
  }
  assert(limited.closed && limitedWal.closed); clean();
  const faulty = memory(walBytes, offset => { if (offset >= BigInt(32 + 24 + metadata.page_size)) throw new Error('WAL 宿主失败'); });
  const paired = memory(baseBytes);
  await assert.rejects(openDatabase(paired, {wal: faulty, tailPolicy: 'valid_prefix', blockSize: 32}), error => error.kind === 'host_failure');
  assert(paired.closed && faulty.closed); clean();
  if (metadata.frames >= 128) {
    const asynchronous = new AbortController(), virtual = memory(walBytes), main = memory(baseBytes);
    let timer;
    try {
      await assert.rejects(openDatabase(main, {wal: virtual, signal: asynchronous.signal,
        onProgress: progress => { if (progress.frames_read === 1 && !timer) timer = setTimeout(() => asynchronous.abort(), 0); }}), CancelledError);
    } finally { clearTimeout(timer); }
    assert(main.closed && virtual.closed); clean();
    const failedClose = memory(baseBytes), other = memory(walBytes);
    failedClose.close = async function() { this.closed = true; throw new Error('模拟宿主关闭失败'); };
    const opened = await openDatabase(failedClose, {wal: other, tailPolicy: 'valid_prefix'});
    await assert.rejects(opened.close(), AggregateError);
    assert(failedClose.closed && other.closed); clean();
  }
}
async function compare(file, wal, prefix = false) {
  const args = wal ? ['--wal', wal, ...(prefix ? ['--wal-prefix'] : [])] : [];
  const source = await openFileSource(file);
  const walSource = wal ? await openFileSource(wal) : null;
  const db = await openDatabase(source, {wal: walSource, tailPolicy: prefix ? 'valid_prefix' : 'strict', blockSize: 512, cachePages: 3});
  const metadata = wal ? {frames: db.source.inspection.frames.length, page_size: db.header.page_size,
    stop_reason: db.source.inspection.stop_reason} : null;
  try {
    assert.deepEqual(db.header, cli(file, args, ['header']));
    if (wal) {
      const expected = cli(file, args, ['wal-info']).wal;
      const actual = structuredClone(db.source.inspection);
      // 异步 WAL 桥接保留 64 位偏移为十进制文本。
      actual.stop_offset = Number(actual.stop_offset); actual.trailing_bytes = Number(actual.trailing_bytes);
      for (const frame of actual.frames) frame.byte_offset = Number(frame.byte_offset);
      assert.deepEqual(actual, expected);
    }
    const schema = await db.schema();
    assert.equal(schema.status, 'complete');
    assert.deepEqual(schema.entries, cli(file, args, ['schema']));
    assert.deepEqual(await db.inspectDatabase(), cli(file, args, ['viewer-data']));
    for (const entry of schema.entries.filter(entry => entry.root_page)) {
      const records = [], scan = db.scan(entry.root_page);
      for await (const record of scan) records.push(record);
      assert.deepEqual(records, cli(file, args, [entry.object_type === 'index' ? 'index' : 'records', entry.name]));
      const {status, reason, ...summary} = scan.result;
      assert.equal(status, 'complete');
      assert.deepEqual(summary, cli(file, args, ['scan', String(entry.root_page)]));
      assert.deepEqual(await db.inspectPage(entry.root_page), cli(file, args, ['page-inspect', String(entry.root_page)]));
    }
  } finally { await db.close(); }
  assert(source.closed); if (walSource) assert(walSource.closed);
  clean();
  return metadata;
}
function memory(bytes, behavior = () => {}) {
  return {size: BigInt(bytes.length), reads: [], closed: false,
    async read(offset, count, {signal} = {}) {
      this.reads.push({offset, count});
      const supplied = await behavior(offset, count, signal);
      return supplied ?? bytes.slice(Number(offset), Number(offset) + count);
    }, async close() { this.closed = true; }};
}
async function lifecycle() {
  const bytes = new Uint8Array(fs.readFileSync('fixtures/core.sqlite'));
  const invalidCache = memory(bytes);
  await assert.rejects(openDatabase(invalidCache, {blockSize: 0}), TypeError);
  assert(invalidCache.closed); clean();
  const invalidWal = {...memory(bytes), size: -1n}, validMain = memory(bytes);
  await assert.rejects(openDatabase(validMain, {wal: invalidWal}), error => error.kind === 'range_out_of_bounds');
  assert(invalidWal.closed && validMain.closed); clean();
  const retained = memory(bytes);
  await assert.rejects(openDatabase(retained, {blockSize: 0, closeSources: false}), TypeError);
  assert(!retained.closed); await retained.close(); clean();
  await assert.rejects(openDatabase(memory(new Uint8Array(32))), error => error.kind === 'range_out_of_bounds'); clean();
  const wrongSchema = new Uint8Array(fs.readFileSync('fixtures/empty.sqlite')); wrongSchema[100] = 10;
  const notTable = await openDatabase(memory(wrongSchema));
  assert.equal((await notTable.schema()).status, 'failed'); await notTable.close(); clean();
  const source = memory(bytes), db = await openDatabase(source, {blockSize: 512, cachePages: 2});
  const scan = db.scan(3);
  const first = await scan.next(); assert(!first.done);
  const reads = source.reads.length;
  await sleep(20); assert.equal(source.reads.length, reads, '等待消费者时不得预读');
  await scan.return(); assert.equal(scan.result.reason, 'visitor_stopped');
  assert.equal(scan.result.records_read, 1);
  const visitorController = new AbortController();
  const blocked = db.scanBtree(3, () => new Promise(() => {}), {signal: visitorController.signal});
  await sleep(10); visitorController.abort();
  assert.equal((await blocked).reason, 'cancelled');
  const limited = await db.scanBtree(3, () => true, {limit: 2});
  assert.equal(limited.reason, 'record_limit'); assert.equal(limited.records_read, 2);
  const budget = await db.scanBtree(3, () => true, {max_total_payload_bytes: 1n});
  assert.equal(budget.reason, 'limit_exceeded'); assert.equal(budget.status, 'incomplete');
  const globalController = new AbortController();
  const partial = await db.inspectDatabase({signal: globalController.signal, onProgress: progress => {
    if (progress.records_read > 10) globalController.abort();
  }});
  assert.equal(partial.reason, 'cancelled'); assert.equal(partial.inspection.status, 'incomplete');
  assert(partial.inspection.records_decoded > 10); assert(partial.locations.some(Boolean));
  assert.equal((await db.inspectPage(0)).status, 'incomplete');
  await db.close(); assert(source.closed); clean();
  for (const kind of ['host_failure', 'short_read']) {
    const faulty = memory(bytes, offset => {
      if (offset >= 1024n) { if (kind === 'short_read') return new Uint8Array(0); throw new Error('模拟读取失败'); }
    });
    const db = await openDatabase(faulty, {blockSize: 512, cachePages: 1});
    const result = await db.scanBtree(3, () => true);
    assert.equal(result.reason, kind); assert.equal(result.status, 'incomplete'); assert.equal(result.location.phase, 'read_page');
    const report = await db.inspectDatabase();
    assert.equal(report.inspection.status, 'incomplete');
    assert(report.inspection.issues.some(issue => issue.message?.includes(`source/${kind}`)));
    await db.close(); clean();
  }
  let release, entered;
  const requested = new Promise(done => { entered = done; });
  const delayed = memory(bytes, async offset => {
    if (offset > 0n) { entered(); return new Promise(done => { release = done; }); }
  });
  const opened = await openDatabase(delayed, {blockSize: 512, cachePages: 1});
  const pending = opened.scanBtree(3, () => true);
  await requested; await opened.close();
  assert.equal((await pending).reason, 'cancelled'); assert(delayed.closed);
  release(new Uint8Array(512)); await sleep(10); clean();
  const old = memory(bytes), cached = new CachedSource(old, {blockSize: 8, cachePages: 2});
  const copied = await cached.read(0n, 8); copied[0] ^= 255;
  assert.equal((await cached.read(0n, 8))[0], bytes[0]);
  await cached.read(7n, 20); assert.equal(cached.blocks.size, 2);
  await cached.close(); assert.equal(cached.blocks.size, 0); assert(old.closed);
  const broken = new CachedSource(memory(bytes, () => new Uint8Array(0)), {blockSize: 8, cachePages: 1});
  await assert.rejects(broken.read(0n, 1), error => error.kind === 'short_read');
  assert.equal(broken.blocks.size, 0); await broken.close();
  await assert.rejects(readExact(memory(bytes), -1n, 1), error => error instanceof SourceError && error.kind === 'range_out_of_bounds');
  const pre = new AbortController(); pre.abort(); const untouched = memory(bytes);
  await assert.rejects(openDatabase(untouched, {signal: pre.signal}), CancelledError);
  assert.equal(untouched.reads.length, 0); assert(untouched.closed); clean();
  const mutated = '_build/async-mutated.sqlite'; fs.writeFileSync(mutated, bytes);
  const immutable = await openFileSource(mutated);
  fs.appendFileSync(mutated, new Uint8Array(1));
  await assert.rejects(immutable.read(0n, 1), error => error.kind === 'host_failure');
  await immutable.close(); fs.unlinkSync(mutated);
  const sparse = path.join(root, '_build/async-sparse.bin');
  const fd = fs.openSync(sparse, 'w+');
  try {
    if (process.platform === 'win32') {
      const marked = spawnSync('fsutil', ['sparse', 'setflag', sparse], {encoding: 'utf8'});
      assert.equal(marked.status, 0, marked.stderr);
    }
    fs.ftruncateSync(fd, 2147484160); fs.writeSync(fd, Buffer.from('wide'), 0, 4, 2147483648);
    const wide = await openFileSource(sparse);
    try { assert.equal(Buffer.from(await wide.read(2147483648n, 4)).toString(), 'wide'); }
    finally { await wide.close(); }
  } finally { fs.closeSync(fd); fs.unlinkSync(sparse); }
  const high = 9007199254740993n;
  const virtual = {size: high + 4n, async read(offset, count) { assert.equal(offset, high); return new Uint8Array(count); }};
  assert.equal((await readExact(virtual, high, 4)).length, 4);
}
if (process.argv[2] === '--snapshot') {
  const metadata = await compare(process.argv[3], process.argv[4], process.argv[5] === 'prefix');
  await walLifecycle(process.argv[3], process.argv[4], metadata);
  console.log(`Verified asynchronous WAL snapshot: ${path.basename(path.dirname(process.argv[3]))}`);
} else {
  const fixtures = fs.readdirSync('fixtures').filter(name => name.endsWith('.sqlite'));
  for (const name of fixtures) { await compare(path.join('fixtures', name)); console.log(`Verified asynchronous fixture: ${name}`); }
  const damaged = new Uint8Array(fs.readFileSync('fixtures/btree.sqlite')); damaged[107] = 61;
  const bad = await openDatabase(new BlobSource(new Blob([damaged])));
  assert.equal((await bad.inspectDatabase()).inspection.status, 'failed'); await bad.close(); clean();
  await lifecycle();
  console.log(`Verified async/sync equivalence for ${fixtures.length} fixtures, cancellation, backpressure, failures, budgets, cache and release`);
}
