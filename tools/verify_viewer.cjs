'use strict';
// 使用独立 JavaScript 环境执行发布 HTML 中的同一解析器，核实离线打包和导航数据。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const document = fs.readFileSync(path.join(root, '_build/moonsqlitefile-viewer.html'), 'utf8');
function embedded(id) {
  const match = document.match(new RegExp(`<script id="${id}" type="application/json">([\\s\\S]*?)</script>`));
  assert(match, id);
  return JSON.parse(match[1]);
}
assert(!/__PARSER_SOURCE__|__VIEWER_JS__|__VIEWER_CSS__|__DEMO_BYTES__|__VERSION__/.test(document));
assert(!/<(?:script|link|iframe)[^>]+(?:src|href)=/i.test(document));
assert(document.includes("connect-src 'none'"));
const source = embedded('parser-source');
const demo = Buffer.from(embedded('demo-bytes'), 'base64');
assert.deepEqual(demo, fs.readFileSync(path.join(root, 'fixtures/btree.sqlite')));
function inspect(bytes, command) {
  let result, error, code = 0;
  const context = vm.createContext({
    TextDecoder, TextEncoder, console,
    moonsqlitefileHost: {args: ['local.sqlite', ...command], bytes: new Uint8Array(bytes),
      output: text => { result = JSON.parse(text); }, error: text => { error = text; code = 1; },
      exitCode: value => { code = value; }}
  });
  new vm.Script(source).runInContext(context, {timeout: 10000});
  return {result, error, code};
}
const {result: data, code} = inspect(demo, ['viewer-data']);
assert.equal(code, 0);
assert.equal(data.inspection.status, 'complete');
assert.equal(data.locations.length, data.inspection.issues.length);
assert.deepEqual(data.summary, inspect(demo, ['summary-json']).result);
assert.deepEqual(data.header, inspect(demo, ['header']).result);
const pages = new Map(data.inspection.pages.map(page => [page.page_number, page]));
assert.equal(pages.size, data.header.page_count);
for (const owner of pages.values()) {
  if (owner.parent_page != null) assert(pages.has(owner.parent_page));
  if (owner.root_page != null) assert(pages.has(owner.root_page));
  if (!['btree_root', 'btree_child'].includes(owner.kind)) continue;
  const page = inspect(demo, ['page-inspect', String(owner.page_number)]);
  assert.equal(page.code, 0);
  assert.equal(page.result.page.number, owner.page_number);
  const fields = ['database_header_bytes','btree_header_bytes','pointer_bytes','unallocated_bytes',
    'cell_bytes','freeblock_bytes','fragmented_bytes','reserved_bytes'];
  assert.equal(fields.reduce((sum, field) => sum + page.result.statistics[field], 0), data.header.page_size);
}
const damaged = Buffer.from(demo);
damaged[107] = 61;
const failure = inspect(damaged, ['viewer-data']);
assert.equal(failure.code, 1);
assert.equal(failure.result.inspection.status, 'failed');
assert(failure.result.locations.some(location => location?.page_number === 1));
assert.equal(inspect(Buffer.alloc(32), ['viewer-data']).code, 1);
console.log(`Verified standalone offline viewer: ${pages.size} pages, root/parent relations, page statistics and located failure`);
