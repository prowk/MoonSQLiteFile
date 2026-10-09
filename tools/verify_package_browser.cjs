// 从实际安装的 npm tarball 载入浏览器示例，所有数据库输入仅通过 File 传给模块。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const playwright = require(process.env.MOONSQLITE_PLAYWRIGHT || 'playwright');
const directory = path.resolve(process.argv[2]);
const root = path.resolve(__dirname, '..');
(async () => {
  const requests = [];
  const server = http.createServer((req, res) => {
    const name = req.url.slice('/MoonSQLiteFile/'.length);
    if (!req.url.startsWith('/MoonSQLiteFile/') || !['index.mjs', 'core.mjs', 'example-browser.mjs'].includes(name)) {
      res.writeHead(404); res.end(); return;
    }
    res.setHeader('Content-Type', 'text/javascript'); res.end(fs.readFileSync(path.join(directory, name)));
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const browser = await playwright.chromium.launch({headless: true, ...(process.env.MOONSQLITE_BROWSER ? {executablePath: process.env.MOONSQLITE_BROWSER} : {})});
  try {
    const page = await browser.newPage();
    page.on('request', req => requests.push({url: req.url(), method: req.method()}));
    const base = `http://127.0.0.1:${server.address().port}/MoonSQLiteFile/`;
    await page.goto(base+'example-browser.mjs');
    const result = await page.evaluate(async ({url, bytes}) => {
      const {previewBlobs} = await import(url);
      return previewBlobs(new File([new Uint8Array(bytes)], 'copy.sqlite'));
    }, {url: base+'example-browser.mjs', bytes: [...fs.readFileSync(path.join(root, 'fixtures/core.sqlite'))]});
    assert.equal(result.schema.status, 'complete'); assert.equal(result.rows.length, 3);
    assert.equal(typeof result.rows[0].rowid, 'string');
    assert(requests.every(req => req.method === 'GET' && req.url.startsWith(base)));
    console.log('Installed tarball browser module/example, subpath and no input uploads passed');
  } finally { await browser.close(); await new Promise(done => server.close(done)); }
})().catch(error => { console.error(error); process.exitCode = 1; });
