'use strict';
// 固定种子的变更在有内存上限的 Worker 中执行；失败样本与元数据可独立重放。
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {Worker, isMainThread, parentPort} = require('node:worker_threads');
const root = path.resolve(__dirname, '..');
if (!isMainThread) {
  require(path.join(root, '_build/js/debug/build/cmd/fuzz/fuzz.js'));
  parentPort.on('message', ({bytes, page, base}) => {
    try { parentPort.postMessage({result: base == null ? globalThis.moonsqlitefileFuzz(bytes, page) : globalThis.moonsqlitefileWalFuzz(base, bytes)}); }
    catch (error) { parentPort.postMessage({error: error.stack || String(error)}); }
  });
} else {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
async function main() {
  const args = process.argv.slice(2);
  let seed = 20261003, iterations = 512, replay = null;
  for (let i = 0; i < args.length; i += 2) {
    if (args[i] === '--seed') seed = numeric(args[i + 1], 0xffffffff);
    else if (args[i] === '--iterations') iterations = numeric(args[i + 1], 1000000);
    else if (args[i] === '--replay' && args[i + 1]) replay = path.resolve(args[i + 1]);
    else throw new Error('用法：node tools/fuzz.cjs [--seed UINT32] [--iterations 1..1000000] [--replay FILE]');
  }
  let state = seed || 0x9e3779b9;
  const random = n => { state ^= state << 13; state ^= state >>> 17; state ^= state << 5; return (state >>> 0) % n; };
  const names = ['empty.sqlite','core.sqlite','btree.sqlite','utf16le.sqlite','utf16be.sqlite','page65536.sqlite'];
  const corpus = names.map(name => fs.readFileSync(path.join(root, 'fixtures', name)));
  const walCorpus = corpus.map((base, index) => makeWal(base, index % 2 === 0));
  const worker = new Worker(__filename, {resourceLimits: {maxOldGenerationSizeMb: 128, stackSizeMb: 4}});
  let fatal = null, pending = null;
  worker.on('error', error => { fatal = error; if (pending) pending.reject(error); });
  worker.on('exit', code => { fatal ||= new Error(`模糊测试 Worker 提前退出：${code}`); if (pending) pending.reject(fatal); });
  worker.on('message', message => {
    if (!pending) return;
    message.error ? pending.reject(new Error(message.error)) : pending.resolve(message.result);
  });
  const counts = {};
  async function execute(bytes, page, metadata, base = null) {
    try {
      const result = await new Promise((resolve, reject) => {
        if (fatal) return reject(fatal);
        const timeout = setTimeout(() => pending.reject(new Error('单个输入超过 5 秒')), 5000);
        pending = {resolve: value => { clearTimeout(timeout); pending = null; resolve(value); },
          reject: error => { clearTimeout(timeout); pending = null; reject(error); }};
        worker.postMessage({bytes: new Uint8Array(bytes), page, base: base == null ? null : new Uint8Array(base)});
      });
      if (!['accepted','invalid','unsupported','limited'].includes(result)) throw new Error(`未知结果：${result}`);
      const label = base == null ? result : `wal_${result}`;
      counts[label] = (counts[label] || 0) + 1;
    } catch (error) {
      const directory = path.join(root, '_build/fuzz-failures'); fs.mkdirSync(directory, {recursive: true});
      const hash = crypto.createHash('sha256').update(bytes).update(base ?? Buffer.alloc(0)).digest('hex');
      fs.writeFileSync(path.join(directory, `${hash}.sqlite`), bytes);
      if (base != null) fs.writeFileSync(path.join(directory, `${hash}.base.sqlite`), base);
      fs.writeFileSync(path.join(directory, `${hash}.json`), JSON.stringify({...metadata, seed, page,
        probes: ['legacy','range','adapter','range_cache','adapter_cache','fault_reports'], sha256: hash, bytes: bytes.length, error: error.stack || String(error)}, null, 2), 'utf8');
      throw new Error(`模糊测试失败，样本：_build/fuzz-failures/${hash}.sqlite\n${error.stack || error}`);
    }
  }
  try {
    if (replay) {
      const metadata = JSON.parse(fs.readFileSync(replay.replace(/\.sqlite$/, '.json'), 'utf8'));
      const base = metadata.kind === 'wal' ? fs.readFileSync(replay.replace(/\.sqlite$/, '.base.sqlite')) : null;
      await execute(fs.readFileSync(replay), metadata.page, {...metadata, replay}, base);
    } else {
      // 原始 corpus 先运行一次；正常错误并不证明变更后的输入必然损坏。
      for (let i = 0; i < corpus.length; i++) await execute(corpus[i], 1, {corpus: names[i], iteration: -1});
      for (let i = 0; i < walCorpus.length; i++) await execute(walCorpus[i], 1, {kind:'wal', corpus:names[i], iteration:-1}, corpus[i]);
      for (let iteration = 0; iteration < iterations; iteration++) {
        const isWal = iteration % 4 === 0;
        const selectedCorpus = isWal ? walCorpus : corpus;
        const index = random(selectedCorpus.length), original = selectedCorpus[index];
        let bytes = Buffer.from(original);
        const rawSize = isWal ? bytes.readUInt32BE(8) : bytes.readUInt16BE(16);
        const mode = random(7), size = rawSize === 1 ? 65536 : rawSize;
        const page = 1 + random(Math.max(1, isWal ? Math.floor((bytes.length - 32) / (size + 24)) : Math.floor(bytes.length / size)));
        const header = isWal ? 32 + (page - 1) * (size + 24) : (page - 1) * size + (page === 1 ? 100 : 0);
        if (mode === 0) {
          for (let n = 1 + random(8); n > 0; n--) bytes[random(bytes.length)] ^= 1 << random(8);
        } else if (mode === 1) {
          bytes = bytes.subarray(0, random(bytes.length + 1));
        } else if (mode === 2) {
          const offset = header + random(Math.min(32, bytes.length - header));
          bytes[offset] = [0,1,2,5,10,13,60,61,127,128,255][random(11)];
        } else if (mode === 3) {
          const fields = isWal ? [0,4,8,12,16,20,24,28,header,header + 4,header + 8,header + 12] : [16,18,19,20,24,28,32,36,40,44,52,56,60,64,92,96];
          const offset = fields[random(fields.length)];
          bytes.writeUInt32BE([0,1,2,0x7fffffff,0xffffffff][random(5)], offset);
        } else if (mode === 4) {
          const offset = random(bytes.length - 4);
          bytes.writeUInt32BE([0,1,2,0xffffffff][random(4)], offset);
        } else if (mode === 5) {
          const start = random(bytes.length), count = Math.min(1 + random(64), bytes.length - start);
          for (let n = 0; n < count; n++) bytes[start + n] = random(256);
        } else {
          const other = selectedCorpus[random(selectedCorpus.length)], start = random(bytes.length);
          const count = Math.min(1 + random(size), bytes.length - start, other.length);
          const source = random(other.length - count + 1);
          other.copy(bytes, start, source, source + count);
        }
        // 部分 WAL 变更重算 checksum，让损坏页内容继续进入覆盖源与数据库检查器。
        if (isWal && iteration % 8 === 0) refreshWalChecksums(bytes);
        await execute(bytes, page, {kind: isWal ? 'wal' : 'db', corpus: names[index], iteration, mutation: mode}, isWal ? corpus[index] : null);
      }
    }
    console.log(`Fuzz passed: seed=${seed}, mutations=${replay ? 'replay' : iterations}, entrypoints=legacy/range/adapter+cache/fault_reports, corpus=${corpus.length}, wal_corpus=${walCorpus.length}, results=${JSON.stringify(counts)}`);
  } finally { await worker.terminate(); }
}
function numeric(text, maximum) {
  if (!text || !/^\d+$/.test(text) || !Number.isSafeInteger(Number(text)) || Number(text) < 1 || Number(text) > maximum) throw new Error('数值参数超出允许范围');
  return Number(text);
}

// 基于真实数据库页构造确定性的双字节序 WAL，并追加未提交的页 1 更新。
function makeWal(base, little) {
  const rawSize = base.readUInt16BE(16), size = rawSize === 1 ? 65536 : rawSize;
  const pages = base.length / size, frameSize = size + 24;
  const bytes = Buffer.alloc(32 + (pages + 1) * frameSize);
  bytes.writeUInt32BE(little ? 0x377f0682 : 0x377f0683, 0);
  bytes.writeUInt32BE(3007000, 4); bytes.writeUInt32BE(size, 8);
  bytes.writeUInt32BE(0x11223344, 16); bytes.writeUInt32BE(0x55667788, 20);
  for (let i = 0; i <= pages; i++) {
    const offset = 32 + i * frameSize, number = i === pages ? 1 : i + 1;
    bytes.writeUInt32BE(number, offset);
    bytes.writeUInt32BE(i === pages - 1 ? pages : 0, offset + 4);
    bytes.writeUInt32BE(0x11223344, offset + 8); bytes.writeUInt32BE(0x55667788, offset + 12);
    base.copy(bytes, offset + 24, (number - 1) * size, number * size);
  }
  bytes[32 + pages * frameSize + 24 + 63] ^= 1;
  refreshWalChecksums(bytes);
  return bytes;
}

function refreshWalChecksums(bytes) {
  if (bytes.length < 32) return;
  const magic = bytes.readUInt32BE(0), size = bytes.readUInt32BE(8);
  if (![0x377f0682,0x377f0683].includes(magic) || size < 512 || size > 65536 || (size & (size - 1)) || (bytes.length - 32) % (size + 24)) return;
  let a = 0, b = 0;
  const word = offset => magic === 0x377f0682 ? bytes.readUInt32LE(offset) : bytes.readUInt32BE(offset);
  const accumulate = (offset, length) => {
    for (let i = offset; i < offset + length; i += 8) { a = (a + word(i) + b) >>> 0; b = (b + word(i + 4) + a) >>> 0; }
  };
  accumulate(0, 24); bytes.writeUInt32BE(a, 24); bytes.writeUInt32BE(b, 28);
  for (let offset = 32; offset < bytes.length; offset += size + 24) {
    accumulate(offset, 8); accumulate(offset + 24, size);
    bytes.writeUInt32BE(a, offset + 16); bytes.writeUInt32BE(b, offset + 20);
  }
}
