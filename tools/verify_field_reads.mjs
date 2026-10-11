// 对照完整解码、投影和跨页分块，并核对未读损坏、取消和源生命周期。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {openDatabase, CancelledError, ParameterError, SourceError, reportEnvelope} from '../_build/async-adapter/index.mjs';
import {openFileSource} from '../_build/async-adapter/node.mjs';
import core from '../_build/async-adapter/core.mjs';

const clean = () => assert.deepEqual(core({op: 'stats'}).result,
  {contexts: 0, scans: 0, inspections: 0, wals: 0, indexes: 0});
for (const name of ['core', 'btree', 'utf16le', 'utf16be', 'page65536']) {
  const db = await openDatabase(await openFileSource(`fixtures/${name}.sqlite`));
  try {
    for (const entry of (await db.schema()).entries.filter(entry => entry.root_page)) {
      const expected = [], scan = db.scan(entry.root_page, {limit: 3});
      for await (const record of scan) expected.push(record);
      const projected = db.scanProjected(entry.root_page, {limit: 3, max_field_bytes: 65536});
      let count = 0;
      for await (const record of projected) {
        const full = expected[count++];
        assert.deepEqual(record.values.map(value => value.value), full.values);
        assert.equal(record.record_complete, true);
        for (const value of record.values.filter(value => value.value.type === 'blob')) {
          const offset = Math.floor(value.field.byte_length / 2);
          const chunk = await db.readBlobChunk(record, value.field.index, {offset, length: 7});
          assert.equal(Buffer.from(chunk.bytes).toString('hex'), value.value.value.slice(offset * 2, (offset + 7) * 2));
        }
      }
      assert.equal(count, expected.length);
    }
  } finally { await db.close(); }
  clean();
}

// 相同静态定位在扫描前进或结束后仍可读取，返回值独立于核心句柄。
const db = await openDatabase(await openFileSource('_build/browser-acceptance/blob-batch.sqlite'));
const scan = db.scanProjected(2, {fields: [1], max_field_bytes: 17});
const first = (await scan.next()).value;
assert.equal(first.values[0].returned_bytes, 17);
assert.equal(first.values[0].field.byte_length, 4194304);
assert.equal(first.record_complete, false);
await scan.next(); await scan.return();
const retained = await db.readBlobChunk(first, 1, {offset: 4089, length: 31});
assert.equal(retained.bytes.length, 31); assert(retained.bytes.every(byte => byte === 0));
assert.equal((await db.readBlobChunk(first, 1, {offset: 4194304})).bytes.length, 0);
await assert.rejects(db.readBlobChunk(first, 1, {offset: 4194305}), ParameterError);
await assert.rejects(db.previewRecord(first, {max_total_copy_bytes: 1n}), error => error.kind === 'limit_exceeded');
await assert.rejects(db.previewRecord(first, {fields: [0, 0]}), ParameterError);
const projection = db.scanProjected(2, {fields: [0], limit: 1});
for await (const record of projection) assert.equal(record.values.length, 1);
assert.equal(reportEnvelope(projection.result, {scope: 'records_projection'}).partial, true);
await db.close();
assert(retained.bytes.every(byte => byte === 0));
await assert.rejects(db.readBlobChunk(first, 1), SourceError); clean();

// 损坏未读取的链尾：短预览不得声称完整；完整读取必须发现损坏。
const bytes = new Uint8Array(fs.readFileSync('_build/browser-acceptance/blob-batch.sqlite'));
const pageSize = 4096;
// 根据 cell 的真实 local payload 位置取得第一 overflow 指针，避免依赖页尾恰好对齐。
function varint(position) { let value = 0n; for (let n = 0; n < 9; n++) {
  const byte = bytes[position++]; value = n === 8 ? (value << 8n) | BigInt(byte) : (value << 7n) | BigInt(byte & 127);
  if (n === 8 || byte < 128) return {value: Number(value), position};
} }
const cell = (first.page_number - 1) * pageSize + first.cell_offset;
const payload = varint(cell), rowid = varint(payload.position);
const minimum = Math.floor((pageSize - 12) * 32 / 255) - 23, maximum = pageSize - 35;
const remainder = minimum + ((payload.value - minimum) % (pageSize - 4));
const local = payload.value <= maximum ? payload.value : remainder <= maximum ? remainder : minimum;
const view = new DataView(bytes.buffer), firstOverflow = view.getUint32(rowid.position + local);
let tail = firstOverflow;
while (view.getUint32((tail - 1) * pageSize)) tail = view.getUint32((tail - 1) * pageSize);
view.setUint32((tail - 1) * pageSize, firstOverflow);
function memory(data, hook) { return {size: BigInt(data.length), closed: false,
  async read(offset, count, options) { await hook?.(offset, options); return data.slice(Number(offset), Number(offset) + count); },
  async close() { this.closed = true; }}; }
const damaged = await openDatabase(memory(bytes));
const prefix = await damaged.previewRecord(first, {fields: [1], max_field_bytes: 17});
assert.equal(prefix.overflow_chain_complete, false);
await assert.rejects(damaged.readBlobChunk(first, 1, {offset: 4194300, length: 4}), error => error.kind === 'invalid');
await damaged.close(); clean();

// 正在等待宿主页面时取消或关闭，必须拒绝操作、释放所有句柄，已有分块仍有效。
for (const closing of [false, true]) {
  const entered = Promise.withResolvers(), gate = Promise.withResolvers(); let block = false;
  const source = memory(bytes, async () => { if (block) { entered.resolve(); await gate.promise; } });
  const active = await openDatabase(source, {cachePages: 1}); block = true;
  const controller = new AbortController();
  const pending = active.readBlobChunk(first, 1, {offset: 1048576, signal: controller.signal});
  const rejected = assert.rejects(pending, CancelledError);
  await entered.promise;
  const shutdown = closing ? active.close() : (controller.abort(), Promise.resolve());
  await rejected; await shutdown; gate.resolve();
  if (!closing) await active.close(); assert(source.closed); clean();
}
const faulty = await openDatabase(memory(bytes, offset => { if (offset >= BigInt(pageSize)) throw new Error('模拟读取失败'); }));
await assert.rejects(faulty.previewRecord(first), SourceError); await faulty.close(); clean();
for (const encoding of ['UTF-8', 'UTF-16le', 'UTF-16be']) {
  const encoded = await openDatabase(await openFileSource(`_build/field-read-fixtures/${encoding}.sqlite`));
  const cursor = encoded.scanProjected(2, {fields: [0], max_field_bytes: 5});
  const record = (await cursor.next()).value; await cursor.return();
  assert.equal(record.values[0].value.value, '🍙');
  assert.equal(record.values[0].returned_bytes, 4);
  assert.equal(record.record_complete, false);
  const tail = await encoded.previewRecord(record, {fields: [2], max_field_bytes: 32});
  assert.equal(tail.values[0].value.value, '末尾🍙');
  await encoded.close(); clean();
}
const wide = await openDatabase(await openFileSource('_build/field-read-fixtures/header.sqlite'));
const headerScan = wide.scanProjected(2, {fields: [1799]});
const headerRecord = (await headerScan.next()).value; await headerScan.return();
assert.equal(headerRecord.header.fields.length, 1800);
assert(headerRecord.header.header_bytes > 512);
assert.equal(headerRecord.values[0].value.value, '最后');
await assert.rejects(wide.previewRecord(headerRecord, {max_header_bytes: 512}), error => error.kind === 'limit_exceeded');
await assert.rejects(wide.previewRecord(headerRecord, {max_fields: 1024}), error => error.kind === 'limit_exceeded');
await wide.close(); clean();
const hugeBytes = new Uint8Array(fs.readFileSync('_build/field-read-fixtures/huge.sqlite'));
const huge = await openDatabase(memory(hugeBytes));
const hugeScan = huge.scanProjected(2, {fields: [0], max_field_bytes: 8});
const hugeRecord = (await hugeScan.next()).value; await hugeScan.return();
assert.equal(hugeRecord.values[0].field.byte_length, 25165824);
assert.equal((await huge.readBlobChunk(hugeRecord, 0, {offset: 25165816, length: 8})).bytes.length, 8);
await assert.rejects(huge.scan(2).next(), error => error.kind === 'limit_exceeded');
await huge.close(); clean();
// 未选文本不解码，后续选择同一字段时才发现实际损坏。
const textBytes = Buffer.from('未选择文本'), textOffset = Buffer.from(hugeBytes).indexOf(textBytes);
assert(textOffset > 0); hugeBytes[textOffset] = 255;
const badText = await openDatabase(memory(hugeBytes));
const badScan = badText.scanProjected(2, {fields: [0], max_field_bytes: 8});
const badRecord = (await badScan.next()).value; await badScan.return();
assert.equal(badRecord.record_complete, false);
await assert.rejects(badText.previewRecord(badRecord, {fields: [1]}), error => error.kind === 'invalid');
await badText.close(); clean();
console.log('Field projection, encodings, overflow chunks, unread corruption, retained values, budgets, cancellation and close passed');
