'use strict';
// 执行实际 HTML 内嵌的同一核心和适配器，核对无外部依赖的离线打包契约。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const document = fs.readFileSync(path.join(root, '_build/moonsqlitefile-viewer.html'), 'utf8');
function embedded(id) {
  const match = document.match(new RegExp(`<script id="${id}" type="application/json">([\\s\\S]*?)</script>`));
  assert(match, id); return JSON.parse(match[1]);
}
assert(!/__PARSER_SOURCE__|__WORKER_SOURCE__|__VIEWER_JS__|__VIEWER_CSS__|__DEMO_BYTES__|__VERSION__/.test(document));
assert(!/<(?:script|link|iframe)[^>]+(?:src|href)=/i.test(document));
assert(document.includes("connect-src 'none'"));
const source = embedded('parser-source'), worker = embedded('worker-source');
assert(worker.includes('new BlobSource(message.file)'));
assert(!worker.includes('message.file.arrayBuffer()'));
const demo = Buffer.from(embedded('demo-bytes'), 'base64');
assert.deepEqual(demo, fs.readFileSync(path.join(root, 'fixtures/btree.sqlite')));
const context = vm.createContext({TextDecoder, TextEncoder, console, Blob, Uint8Array,
  AbortController, AbortSignal, setTimeout, clearTimeout});
new vm.Script(source + '\nglobalThis.viewerAPI = {openDatabase, BlobSource};').runInContext(context, {timeout: 10000});
const api = context.viewerAPI;
const plain = value => JSON.parse(JSON.stringify(value));
function cli(command) {
  const result = spawnSync(process.execPath, ['tools/inspect.cjs', 'fixtures/btree.sqlite', ...command], {cwd: root, encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout);
}
(async () => {
  const input = new api.BlobSource(new Blob([demo]));
  const db = await api.openDatabase(input);
  const data = plain(await db.inspectDatabase());
  assert.deepEqual(data, cli(['viewer-data']));
  const pages = new Map(data.inspection.pages.map(page => [page.page_number, page]));
  assert.equal(pages.size, data.header.page_count);
  for (const owner of pages.values()) {
    if (owner.parent_page != null) assert(pages.has(owner.parent_page));
    if (owner.root_page != null) assert(pages.has(owner.root_page));
    if (!['btree_root', 'btree_child'].includes(owner.kind)) continue;
    const page = plain(await db.inspectPage(owner.page_number));
    assert.equal(page.status, 'complete');
    const fields = ['database_header_bytes', 'btree_header_bytes', 'pointer_bytes', 'unallocated_bytes',
      'cell_bytes', 'freeblock_bytes', 'fragmented_bytes', 'reserved_bytes'];
    assert.equal(fields.reduce((sum, field) => sum + page.statistics[field], 0), data.header.page_size);
  }
  await db.close(); assert(input.closed);
  const damaged = Buffer.from(demo); damaged[107] = 61;
  const bad = await api.openDatabase(new api.BlobSource(new Blob([damaged])));
  const failure = plain(await bad.inspectDatabase());
  assert.equal(failure.inspection.status, 'failed');
  assert(failure.locations.some(location => location?.page_number === 1)); await bad.close();
  await assert.rejects(api.openDatabase(new api.BlobSource(new Blob([Buffer.alloc(32)]))));
  assert.deepEqual(plain(context.moonsqlitefileAsyncBridge({op: 'stats'}).result),
    {contexts: 0, scans: 0, inspections: 0, wals: 0, indexes: 0});
  console.log(`Verified standalone offline viewer: ${pages.size} pages, root/parent relations, page statistics and located failure, Blob chunks and resource release`);
})().catch(error => { console.error(error); process.exitCode = 1; });
