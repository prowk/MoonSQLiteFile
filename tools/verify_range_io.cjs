'use strict';
// 对真实稀疏文件、宿主短读及内存输入进行验证，避免只证明解析器自身的假设。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {execFileSync, spawnSync} = require('node:child_process');
const {openFileSource} = require('./range_io.cjs');
const root = path.resolve(__dirname, '..');
const build = path.join(root, '_build');
const directory = fs.mkdtempSync(path.join(build, 'range-io-'));
const cli = path.join(__dirname, 'inspect.cjs');
function run(file, args, code = 0) {
  const result = spawnSync(process.execPath, [cli, file, ...args], {encoding: 'utf8', timeout: 30000});
  assert.equal(result.status, code, result.stderr);
  return {data: JSON.parse(result.stdout), stderr: result.stderr};
}
try {
  const file = path.join(directory, 'large.db');
  fs.writeFileSync(file, new Uint8Array(0));
  // Windows 先显式标记为 sparse，避免用数 GiB 的实际磁盘分配代替稀疏验收。
  if (process.platform === 'win32') execFileSync('fsutil', ['sparse', 'setflag', file]);
  const fd = fs.openSync(file, 'r+');
  try {
    fs.ftruncateSync(fd, 2147484160);
    const first = fs.readFileSync(path.join(root, 'fixtures/empty.sqlite'));
    assert.equal(first.length, 512);
    // 使用物理长度计算逻辑页数。
    first.fill(0, 28, 32);
    fs.writeSync(fd, first, 0, first.length, 0);
    const leaf = Buffer.alloc(512);
    Buffer.from('0d00000000020000', 'hex').copy(leaf);
    fs.writeSync(fd, leaf, 0, leaf.length, 2147483648);
  } finally { fs.closeSync(fd); }
  const header = run(file, ['--io-stats','header']);
  assert.equal(header.data.page_count, 4194305);
  const page = run(file, ['--io-stats','page-inspect','4194305']);
  assert.equal(page.data.status, 'complete');
  assert.equal(page.data.page.number, 4194305);
  const io = JSON.parse(page.stderr).io[0];
  assert.equal(io.reads, 2);
  assert(io.bytes <= 8192 && io.maxRead <= 4096, JSON.stringify(io));
  const partial = run(file, ['inspect'], 2);
  assert.equal(partial.data.status, 'incomplete');
  assert.deepEqual(partial.data.pages, []);
  const source = openFileSource(file);
  try {
    assert.equal(source.size, 2147484160n);
    assert.equal(source.read(2147483648n, 512)[0], 13);
    assert.equal(source.read(source.size, 0).length, 0);
    assert.throws(() => source.read(source.size, 1), /越界/);
    assert.throws(() => source.read(-1n, 1), /越界/);
    const readSync = fs.readSync;
    try { fs.readSync = () => 0; assert.throws(() => source.read(0n, 100), /短读/); }
    finally { fs.readSync = readSync; }
    fs.truncateSync(file, 512);
    assert.throws(() => source.read(0n, 100), /发生变化/);
  } finally { source.close(); }
  source.close();
  assert.throws(() => source.read(0n, 1), /已经关闭/);

  const compiled = fs.readFileSync(path.join(build, 'js/debug/build/cmd/inspect/inspect.js'), 'utf8');
  for (const [name, commands] of [
    ['core', [['header'],['schema'],['rows','samples'],['page-inspect','1'],['inspect-details'],['summary-json']]],
    ['btree', [['index','mixed_index','8'],['records','keyed','8'],['scan','1'],['viewer-data']]],
  ]) {
    const file = path.join(root, `fixtures/${name}.sqlite`);
    for (const command of commands) {
      let result, error, code = 0;
      const context = vm.createContext({TextDecoder, TextEncoder,
        moonsqlitefileHost: {args: [file, ...command], bytes: new Uint8Array(fs.readFileSync(file)),
          output: text => { result = JSON.parse(text); }, error: text => { error = text; code = 1; },
          exitCode: value => { code = value; }}});
      new vm.Script(compiled).runInContext(context, {timeout: 30000});
      assert.equal(error, undefined);
      assert.equal(code, 0);
      assert.deepEqual(run(file, ['--cache-pages','1',...command]).data, result);
    }
  }
  console.log(`Verified range I/O: 2 GiB sparse boundary, ${io.reads} reads/${io.bytes} bytes, short reads, mutation, closure and byte-input equivalence`);
} finally {
  assert.equal(path.dirname(path.resolve(directory)), build);
  fs.rmSync(directory, {recursive: true, force: true});
}
