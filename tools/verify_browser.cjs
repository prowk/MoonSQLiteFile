'use strict';
// 在隔离浏览器中载入单文件页面，随后断网，验证真实 File、Blob、Worker 和 UI。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const {performance} = require('node:perf_hooks');
const root = path.resolve(__dirname, '..');
const playwright = require(process.env.MOONSQLITE_PLAYWRIGHT || 'playwright');
const pagePath = path.join(root, '_build/moonsqlitefile-viewer.html');
const fixtures = path.join(root, '_build/browser-acceptance');
async function main() {
  const evidence = [], requests = [], errors = [];
  const server = http.createServer((request, response) => {
    if (request.url !== '/viewer.html') { response.writeHead(404); response.end(); return; }
    response.setHeader('Content-Type', 'text/html; charset=utf-8'); response.end(fs.readFileSync(pagePath));
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const browser = await playwright.chromium.launch({headless: true,
    ...(process.env.MOONSQLITE_BROWSER ? {executablePath: process.env.MOONSQLITE_BROWSER} : {})});
  try {
    const context = await browser.newContext({viewport: {width: 1440, height: 1000}});
    const page = await context.newPage();
    page.on('pageerror', error => errors.push(error.message));
    page.on('request', request => requests.push(request.url()));
    await page.addInitScript(() => {
      // 只记录公开 Worker 消息与终止，不访问解析器内部状态。
      window.browserEvidence = {created: 0, terminated: 0, closed: [], results: [], progress: []};
      const WorkerClass = window.Worker;
      window.Worker = class extends WorkerClass {
        constructor(...args) {
          super(...args); window.browserEvidence.created++;
          this.addEventListener('message', ({data}) => {
            if (data.closed) window.browserEvidence.closed.push(data.handles);
            if (data.result?.io) window.browserEvidence.results.push(data.result);
            if (data.progress) window.browserEvidence.progress.push(data.progress);
          });
        }
        terminate() { window.browserEvidence.terminated++; return super.terminate(); }
      };
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/viewer.html`);
    await context.setOffline(true);
    async function done(state, timeout = 180000) {
      await page.waitForFunction(expected => document.querySelector('#status').dataset.state === expected &&
        document.querySelector('#cancel').disabled, state, {timeout});
    }
    async function choose(selector, file) { await page.locator(selector).setInputFiles(file); }
    await page.getByRole('button', {name: '载入示例库'}).click(); await done('complete');
    await page.locator('#objects').selectOption('49');
    await page.waitForFunction(() => document.querySelector('#page-title').textContent === '页面 49' &&
      document.querySelector('#page-status').textContent.includes('检查完成'));
    await page.getByRole('button', {name: '下一段', exact: true}).click();
    assert((await page.locator('#raw').textContent()).startsWith('0100'));
    await page.locator('#cells').selectOption({index: 0});
    assert(!(await page.locator('#raw').textContent()).startsWith('0000'));
    await choose('#file', path.join(root, 'fixtures/core.sqlite')); await done('complete');
    assert((await page.locator('#scope').textContent()).includes('最大块 4096'));
    await choose('#file', path.join(fixtures, '512-transactions.db')); await done('complete');
    await choose('#wal-file', path.join(fixtures, '512-transactions.wal')); await done('complete');
    assert((await page.locator('#scope').textContent()).includes('174 已提交帧'));
    let data = await page.evaluate(() => window.browserEvidence.results.at(-1));
    assert.equal(data.header.page_count, 144); assert.equal(data.inspection.records_decoded, 273);
    evidence.push({case: 'db_wal', io: data.io, logical_pages: data.header.page_count});
    await choose('#file', path.join(fixtures, '512-reset.db')); await done('complete');
    await choose('#wal-file', path.join(fixtures, '512-reset.wal')); await done('failed');
    assert((await page.locator('#status').textContent()).includes('UseValidPrefix'));
    await page.getByText('检查预算', {exact: true}).click();
    await page.locator('#wal-prefix').check();
    await page.locator('#start').click(); await done('complete');
    assert((await page.locator('#scope').textContent()).includes('1 已提交帧'));
    await choose('#file', path.join(fixtures, 'damaged.sqlite')); await done('failed');
    assert(await page.locator('#issues button').count() > 0);
    await page.locator('#issues button').first().click();
    await page.waitForFunction(() => document.querySelector('#page-status').textContent.includes('fragment_count'));
    await choose('#file', path.join(fixtures, 'short.sqlite')); await done('failed');
    assert.equal(await page.locator('#overview').isVisible(), false);
    await choose('#file', path.join(fixtures, 'large.sqlite'));
    await page.waitForFunction(() => document.querySelector('#status').textContent.includes('正在检查：'));
    await page.locator('#cancel').click(); await done('incomplete');
    data = await page.evaluate(() => window.browserEvidence.results.at(-1));
    assert.equal(data.reason, 'cancelled'); assert.equal(data.inspection.ownership_complete, false);
    evidence.push({case: 'cancel', records: data.inspection.records_decoded, io: data.io});
    await choose('#file', path.join(fixtures, 'large.sqlite'));
    await choose('#file', path.join(root, 'fixtures/empty.sqlite')); await done('complete');
    assert((await page.locator('#files').textContent()).includes('empty.sqlite'));
    await page.waitForFunction(() => window.browserEvidence.created - window.browserEvidence.terminated === 1);
    await choose('#file', path.join(fixtures, 'large.sqlite')); await done('incomplete');
    data = await page.evaluate(() => window.browserEvidence.results.at(-1));
    assert.equal(data.inspection.records_decoded, 1024);
    assert(data.inspection.issues.some(issue => issue.error_kind === 'limit_exceeded'));
    evidence.push({case: 'default_payload_budget', records: data.inspection.records_decoded, io: data.io});
    await page.locator('#max-payload').fill('128');
    const start = performance.now();
    await page.locator('#start').click(); await done('complete');
    const seconds = (performance.now() - start) / 1000;
    data = await page.evaluate(() => window.browserEvidence.results.at(-1));
    assert.equal(data.inspection.records_decoded, 1101);
    assert.equal(data.header.page_count, 17740); assert.equal(data.io.db.maxRead, 4096);
    assert.equal(data.inspection.payload_bytes, '72094036');
    evidence.push({case: 'large_increased_payload_budget', seconds, io: data.io, records: data.inspection.records_decoded});
    await page.screenshot({path: path.join(fixtures, 'viewer-large.png'), fullPage: true});
    await page.locator('#timeout').fill('1'); await page.locator('#start').click(); await done('incomplete');
    data = await page.evaluate(() => window.browserEvidence.results.at(-1));
    assert.equal(data.reason, 'cancelled');
    assert(data.inspection.issues.some(issue => issue.message?.includes('达到检查时间预算')));
    evidence.push({case: 'time_budget', records: data.inspection.records_decoded, io: data.io});
    await page.locator('#timeout').fill('120'); await page.locator('#max-rows').fill('2');
    await page.locator('#start').click(); await done('incomplete');
    data = await page.evaluate(() => window.browserEvidence.results.at(-1));
    assert.equal(data.inspection.records_decoded, 2);
    assert(data.inspection.issues.some(issue => issue.message?.includes('全局记录数预算已耗尽')));
    await page.locator('#max-rows').fill('100000');
    await page.locator('#max-pages').fill('1'); await page.locator('#start').click(); await done('incomplete');
    data = await page.evaluate(() => window.browserEvidence.results.at(-1));
    assert.equal(data.inspection.pages.length, 0); assert.equal(data.inspection.records_decoded, 0);
    const lifecycle = await page.evaluate(() => window.browserEvidence);
    assert(lifecycle.closed.length > 0);
    for (const handles of lifecycle.closed) assert(Object.values(handles).every(count => count === 0));
    assert.equal(lifecycle.created - lifecycle.terminated, 1);
    assert.equal(errors.length, 0, JSON.stringify(errors));
    assert(requests.every(url => url.startsWith(`http://127.0.0.1:${server.address().port}/`) || url.startsWith('blob:')));
    const report = {browser: browser.version(), origin: 'localhost', offline_after_load: true,
      direct_file_url: 'unverified', external_requests: requests.filter(url => /^https?:/.test(url) && !url.startsWith('http://127.0.0.1:')).length,
      created_workers: lifecycle.created, terminated_workers: lifecycle.terminated, checks: evidence};
    fs.writeFileSync(path.join(root, '_build/browser-acceptance.json'), JSON.stringify(report, null, 2) + '\n', 'utf8');
    console.log(JSON.stringify(report));
    await context.close();
  } finally { await browser.close(); await new Promise(done => server.close(done)); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
