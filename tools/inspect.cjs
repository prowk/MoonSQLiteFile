#!/usr/bin/env node
'use strict';

// 宿主只负责文件与进程 I/O；所有 SQLite 解析都由编译后的 MoonBit 执行。
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
let walPath, walPrefix = false;
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
      } else { throw new Error('无效或重复的 WAL 参数'); }
    }
    if (args.length < 2 || (walPrefix && walPath === undefined)) throw new Error('WAL 参数缺少文件或检查命令');
    if (!compiled) {
      throw new Error('请先执行 moon build --target js cmd/inspect');
    }
    globalThis.moonsqlitefileHost = {
      args, walPrefix,
      ...(walPath === undefined ? {} : {walBytes: new Uint8Array(fs.readFileSync(walPath))}),
      bytes: new Uint8Array(fs.readFileSync(args[0])),
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
  }
}
