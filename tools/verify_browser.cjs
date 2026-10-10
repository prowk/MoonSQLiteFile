'use strict';
// 在隔离浏览器中载入单文件页面，随后断网，验证真实 File、Blob、Worker 和 UI。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const {createHash} = require('node:crypto');
const {performance} = require('node:perf_hooks');
const root = path.resolve(__dirname, '..');
const playwrightPath = process.env.MOONSQLITE_PLAYWRIGHT || 'playwright';
const playwright = require(playwrightPath);
assert.equal(require(path.join(playwrightPath, 'package.json')).version, JSON.parse(fs.readFileSync(path.join(root, 'tools/toolchain.json'), 'utf8')).playwright);
const pagePath = path.join(root, '_build/pages/index.html');
const fixtures = path.join(root, '_build/browser-acceptance');
async function main() {
  const evidence = [], requests = [], methods = [], errors = [];
  const server = http.createServer((request, response) => {
    const name = request.url.slice('/MoonSQLiteFile/'.length);
    if (request.url !== '/MoonSQLiteFile/' && !/^moonsqlitefile-viewer-\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?\.html$/.test(name)) { response.writeHead(404); response.end(); return; }
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end(fs.readFileSync(name ? path.join(root, '_build/pages', name) : pagePath));
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const browser = await playwright.chromium.launch({headless: true, ignoreDefaultArgs: ['--disable-back-forward-cache'],
    // 完整 Chromium 的新 headless 模式支持真实历史恢复，默认 Headless Shell 不覆盖这一能力。
    ...(process.env.MOONSQLITE_BROWSER ? {executablePath: process.env.MOONSQLITE_BROWSER} : {channel: 'chromium'})});
  try {
    const context = await browser.newContext({viewport: {width: 1440, height: 1000}});
    const page = await context.newPage();
    page.on('pageerror', error => errors.push(error.message));
    page.on('request', request => { requests.push(request.url()); methods.push({method: request.method(), body_size: request.postDataBuffer()?.length ?? 0}); });
    await page.addInitScript(() => {
      // 只记录公开 Worker 消息与终止，不访问解析器内部状态。
      window.browserEvidence = {created: 0, terminated: 0, closed: [], results: [], progress: []};
      window.historyRestorations = [];
      window.addEventListener('pageshow', event => window.historyRestorations.push(event.persisted));
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
    const viewerURL = process.env.MOONSQLITE_VIEWER_URL || `http://127.0.0.1:${server.address().port}/MoonSQLiteFile/`;
    await page.goto(viewerURL);
    // 开发预览不在页头或下载入口展示未发布的版本号。
    const sourceVersion = /^version = "([^"]+)"/m.exec(fs.readFileSync(path.join(root, 'moon.mod'), 'utf8'))[1];
    if (sourceVersion.includes('-')) {
      assert((await page.locator('header').textContent()).includes('开发预览'));
      assert(!/v\d+\.\d+/.test(await page.locator('header').textContent()));
      assert(!/v\d+\.\d+/.test(await page.locator('a[download]').textContent()));
    }
    const htmlDownload = page.waitForEvent('download'); await page.locator('a[download]').click();
    const htmlPath = path.join(fixtures, 'downloaded-viewer.html'); await (await htmlDownload).saveAs(htmlPath);
    // 跨平台部署使用该运行的独立 CI 产物作基准，仍逐字节比较下载文件。
    const expectedHTML = fs.readFileSync(process.env.MOONSQLITE_VIEWER_HTML || path.join(root, '_build/moonsqlitefile-viewer.html'));
    assert.deepEqual(fs.readFileSync(htmlPath), expectedHTML);
    await context.setOffline(true);
    async function done(state, timeout = 180000) {
      await page.waitForFunction(expected => document.querySelector('#status').dataset.state === expected &&
        document.querySelector('#cancel').disabled, state, {timeout});
    }
    async function choose(selector, file) {
      await page.locator(selector).setInputFiles([]);
      await page.locator(selector).setInputFiles(file);
      try { await page.waitForFunction(() => ['ready', 'failed'].includes(document.querySelector('#status').dataset.state) && document.querySelector('#cancel').disabled); }
      catch (error) { console.error(await page.locator('#status').textContent(), file, errors); throw error; }
      if (await page.locator('#overview').isVisible()) await page.locator('#start').click();
    }
    await page.getByRole('button', {name: '载入示例库'}).click(); await done('ready');
    let opened = await page.evaluate(() => window.browserEvidence.results.at(-1));
    assert.equal(opened.schema.status, 'complete'); assert.equal(opened.inspection, undefined);
    assert.equal(opened.io.handles.inspections, 0); assert(opened.io.db.bytes < 16384);
    await page.getByText('检查预算', {exact: true}).click();
    await page.locator('#schema-limit').fill('1'); await page.locator('#open').click(); await done('ready');
    opened = await page.evaluate(() => window.browserEvidence.results.at(-1));
    assert.equal(opened.schema.status, 'incomplete'); assert.equal(opened.schema.entries.length, 1);
    assert((await page.locator('#status').textContent()).includes('前缀'));
    const exported = page.waitForEvent('download'); await page.locator('#export').click();
    const saved = path.join(fixtures, 'schema-export.json'); await (await exported).saveAs(saved);
    const envelope = JSON.parse(fs.readFileSync(saved, 'utf8'));
    assert.equal(envelope.scope, 'schema'); assert(envelope.partial); assert.equal(envelope.tool_version, /^version = "([^"]+)"/m.exec(fs.readFileSync(path.join(root, 'moon.mod'), 'utf8'))[1]);
    assert(envelope.diagnostics.some(item => item.category === 'budget'));
    await page.locator('#schema-limit').fill('100'); await page.locator('#open').click(); await done('ready');
    await page.locator('#objects').selectOption('49');
    await page.locator('#preview-batch').fill('2'); await page.locator('#preview-limit').fill('5');
    await page.locator('#preview-start').click();
    await page.waitForFunction(() => document.querySelector('#preview-status').textContent.includes('累计 2 条'));
    assert.equal(await page.locator('#records article').count(), 2);
    const first = await page.locator('#records').textContent();
    await page.locator('#preview-next').click();
    await page.waitForFunction(() => document.querySelector('#preview-status').textContent.includes('累计 4 条'));
    assert.equal(await page.locator('#records article').count(), 2); assert.notEqual(await page.locator('#records').textContent(), first);
    await page.locator('#preview-next').click();
    await page.waitForFunction(() => document.querySelector('#preview-status').textContent.includes('达到累计记录上限'));
    assert.equal(await page.locator('#records article').count(), 1); assert(await page.locator('#preview-next').isDisabled());
    // WITHOUT ROWID 的 rowid 为空，展示明确保留磁盘顺序而非 SQL 列名。
    await page.locator('#objects').selectOption('88');
    await page.locator('#preview-start').click();
    await page.waitForFunction(() => document.querySelector('#preview-status').textContent.includes('累计 2 条'));
    assert((await page.locator('#records').textContent()).includes('rowid 无'));
    await page.locator('#objects').selectOption('143'); await page.locator('#value-limit').fill('16');
    await page.locator('#preview-start').click();
    await page.waitForFunction(() => document.querySelector('#preview-status').textContent.includes('累计 2 条'));
    assert((await page.locator('#records').textContent()).includes('仅展示前 16 字符'));
    const previewDownload = page.waitForEvent('download'); await page.locator('#preview-export').click();
    const previewPath = path.join(fixtures, 'preview-export.json'); await (await previewDownload).saveAs(previewPath);
    const paused = JSON.parse(fs.readFileSync(previewPath, 'utf8'));
    assert.equal(paused.scope, 'records'); assert(paused.partial); assert.equal(paused.result.reason, 'preview_paused');
    await page.screenshot({path: path.join(fixtures, 'viewer-preview.png'), fullPage: true});
    evidence.push({case: 'quick_schema_and_cursor_preview', bytes: opened.io.db.bytes, batch: 2, limit: 5, export_partial: envelope.partial});
    await page.locator('#start').click(); await done('complete');
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
    if (!await page.locator('#wal-prefix').isVisible()) await page.getByText('检查预算', {exact: true}).click();
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
    assert.equal(data.reason, 'limit_exceeded');
    assert(data.export.diagnostics.some(item => item.category === 'budget'));
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
    // 无根页对象可查看定义，但不提供记录操作；长名称和窄屏不得撑开文档。
    await page.locator('#max-pages').fill('100000'); await page.locator('#max-rows').fill('100000');
    await page.locator('#timeout').fill('120'); await page.locator('#max-payload').fill('64');
    await choose('#file', path.join(fixtures, 'objects.sqlite')); await done('complete');
    for (const name of ['event_view', 'event_trigger', 'event_search']) {
      const value = await page.locator('#objects option').filter({hasText: name}).first().getAttribute('value');
      await page.locator('#objects').selectOption(value);
      assert(await page.locator('#preview-start').isDisabled());
      assert((await page.locator('#object-info').textContent()).includes('没有 B-tree 根页'));
      assert(await page.locator('#object-definition').isVisible());
    }
    await page.locator('#objects').selectOption('2');
    await page.locator('#preview-limit').fill('5'); await page.locator('#preview-batch').fill('2');
    await page.locator('#preview-start').focus(); await page.keyboard.press('Space');
    await page.waitForFunction(() => document.querySelector('#preview-status').textContent.includes('累计 2 条'));
    await page.locator('#preview-limit').fill('3'); assert(await page.locator('#preview-next').isDisabled());
    const priorDownload = page.waitForEvent('download'); await page.locator('#preview-export').click();
    const priorPath = path.join(fixtures, 'prior-budget-export.json'); await (await priorDownload).saveAs(priorPath);
    assert.equal(JSON.parse(fs.readFileSync(priorPath, 'utf8')).budgets.limit, 5);
    await page.locator('#preview-start').click();
    await page.waitForFunction(() => document.querySelector('#preview-status').textContent.includes('累计 2 条') && !document.querySelector('#preview-start').disabled);
    await page.locator('#preview-next').click();
    await page.waitForFunction(() => document.querySelector('#preview-status').textContent.includes('达到累计记录上限'));
    for (const width of [1440, 1024, 390]) {
      await page.setViewportSize({width, height: 1000});
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth+1));
      await page.screenshot({path: path.join(fixtures, `viewer-responsive-${width}.png`), fullPage: true});
    }
    await page.locator('#page-number').fill('1'); await page.locator('#page-number').focus();
    await page.keyboard.press('Enter'); await page.waitForFunction(() => document.querySelector('#page-title').textContent === '页面 1');
    await page.locator('#demo').focus(); await page.keyboard.press('Tab');
    assert.equal(await page.evaluate(() => document.activeElement.id), 'open');
    assert.equal(await page.locator('#open').evaluate(element => getComputedStyle(element).outlineWidth), '3px');
    await page.locator('#max-rows').fill('2'); assert(await page.locator('#preview-start').isDisabled());
    await page.locator('#open').click(); await done('ready');
    let restricted = await page.evaluate(() => window.browserEvidence.results.at(-1));
    assert.equal(restricted.export.budgets.limit, 2); assert.equal(restricted.export.budgets.requested_limit, 100);
    await page.locator('#objects').selectOption('2'); await page.locator('#preview-start').click();
    await page.waitForFunction(() => document.querySelector('#preview-status').textContent.includes('实际累计上限 2'));
    assert(await page.locator('#preview-next').isDisabled());
    // 真正的历史恢复必须触发 persisted，而不是用合成事件替代 bfcache。
    await page.goto('about:blank'); await page.goBack({waitUntil: 'commit'}); await done('ready');
    assert(await page.evaluate(() => window.historyRestorations.at(-1) === true));
    assert((await page.locator('#files').textContent()).includes('objects.sqlite'));
    await page.goForward(); assert.equal(page.url(), 'about:blank');
    await page.goBack({waitUntil: 'commit'}); await done('ready');
    assert(await page.evaluate(() => window.historyRestorations.at(-1) === true));
    await page.locator('#objects').selectOption('2'); await page.locator('#preview-start').click();
    await page.waitForFunction(() => document.querySelector('#preview-status').textContent.includes('实际累计上限 2'));
    evidence.push({case: 'rootless_objects_keyboard_responsive_and_history', widths: [1440, 1024, 390], persisted_restorations: 2,
      schema_limit: restricted.export.budgets.limit, previous_preview_budget_preserved: true});
    const lifecycle = await page.evaluate(() => window.browserEvidence);
    assert(lifecycle.closed.length > 0);
    for (const handles of lifecycle.closed) assert(Object.values(handles).every(count => count === 0));
    assert.equal(lifecycle.created - lifecycle.terminated, 1);
    assert.equal(errors.length, 0, JSON.stringify(errors));
    assert(methods.every(item => item.method === 'GET' && item.body_size === 0));
    assert(requests.every(url => url.startsWith(viewerURL) || url.startsWith('blob:')));
    const report = {browser: browser.version(), origin: viewerURL, deployed: Boolean(process.env.MOONSQLITE_VIEWER_URL), offline_after_load: true,
      download_sha256: createHash('sha256').update(expectedHTML).digest('hex'),
      direct_file_url: 'unverified', external_requests: requests.filter(url => /^https?:/.test(url) && !url.startsWith(viewerURL)).length,
      created_workers: lifecycle.created, terminated_workers: lifecycle.terminated, checks: evidence};
    fs.writeFileSync(path.join(root, '_build/browser-acceptance.json'), JSON.stringify(report, null, 2) + '\n', 'utf8');
    console.log(JSON.stringify(report));
    await context.close();
  } finally { await browser.close(); await new Promise(done => server.close(done)); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
