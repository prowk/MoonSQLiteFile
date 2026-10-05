#!/usr/bin/env node
'use strict';

// 宿主只负责文件与进程 I/O；所有 SQLite 解析都由编译后的 MoonBit 执行。
const fs = require('node:fs');
const path = require('node:path');
const {openFileSource} = require('./range_io.cjs');
const args = process.argv.slice(2);
let walPath, walPrefix = false, ioStats = false;
const options = {};
const sources = [];
const started = process.hrtime.bigint();
// 默认构建生成 debug 目录，显式 --release 构建生成 release 目录。
const candidates = ['debug', 'release'].map(mode =>
  path.join(__dirname, '..', '_build', 'js', mode, 'build', 'cmd', 'inspect', 'inspect.js'));
const compiled = candidates.find(file => fs.existsSync(file));

if (args.length < 2) {
  process.stderr.write('用法：node tools/inspect.cjs FILE [--wal WAL [--wal-prefix]] header|schema|page N|page-inspect N|rows TABLE [LIMIT]|records TABLE [LIMIT]|index INDEX [LIMIT]|scan ROOT [LIMIT]|freelist|inspect|inspect-details|tree-inspect ROOT [LIMIT]|summary|summary-json|viewer-data|wal-inspect|wal-info\n');
  process.exitCode = 1;
} else {
  try {
    while (args[1]?.startsWith('--')) {
      const option = args.splice(1, 1)[0];
      if (option === '--wal' && walPath === undefined && args[1] && !args[1].startsWith('--')) {
        walPath = args.splice(1, 1)[0];
      } else if (option === '--wal-prefix' && !walPrefix) {
        walPrefix = true;
      } else if (option === '--io-stats' && !ioStats) {
        ioStats = true;
      } else if (option === '--max-total-payload-bytes' && options[option.slice(2)] === undefined && /^(0|[1-9][0-9]*)$/.test(args[1] || '')) {
        const value = BigInt(args.splice(1, 1)[0]);
        if (value > 18446744073709551615n) throw new Error('累计 payload 参数超出 UInt64 范围');
        options[option.slice(2)] = value;
      } else if (['--cache-pages','--max-frames','--max-overlay-pages','--max-pages','--max-rows','--max-issues','--max-report-pages','--max-payload-bytes'].includes(option) && options[option.slice(2)] === undefined && /^[1-9][0-9]*$/.test(args[1] || '')) {
        const value = Number(args.splice(1, 1)[0]);
        if (!Number.isSafeInteger(value) || value > 2147483647) throw new Error('资源参数超出 Int 范围');
        options[option.slice(2)] = value;
      } else { throw new Error('无效或重复的检查参数'); }
    }
    if (args.length < 2 || (walPrefix && walPath === undefined)) throw new Error('WAL 参数缺少文件或检查命令');
    if (!compiled) {
      throw new Error('请先执行 moon build --target js src/cmd/inspect');
    }
    const base = openFileSource(args[0]);
    sources.push(base);
    const wal = walPath === undefined ? undefined : openFileSource(walPath);
    if (wal) sources.push(wal);
    globalThis.moonsqlitefileHost = {
      args, walPrefix, options,
      fileSize: base.size, readRange: (offset, count) => base.read(offset, count),
      ...(wal ? {walSize: wal.size, readWalRange: (offset, count) => wal.read(offset, count)} : {}),
      output: text => process.stdout.write(`${text}\n`),
      exitCode: code => { process.exitCode = code; },
      error: text => {
        process.stderr.write(`${text}\n`);
        process.exitCode = 1;
      },
    };
    require(compiled);
  } catch (error) {
    process.stderr.write(`MoonSQLiteFile: ${error.message}\n`);
    process.exitCode = 1;
  } finally {
    for (const source of sources) source.close();
    if (ioStats) process.stderr.write(JSON.stringify({io: sources.map(source => source.statistics), seconds: Number(process.hrtime.bigint() - started) / 1e9, peakRss: Math.max(process.resourceUsage().maxRSS * 1024, process.memoryUsage().rss, ...sources.map(source => source.statistics.peakRss))}) + '\n');
  }
}
