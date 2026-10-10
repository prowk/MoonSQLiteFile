'use strict';
// 对真实浏览器进程记录操作系统内存高水位；Worker 消息只保留大小摘要。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const {execFileSync} = require('node:child_process');
const {performance} = require('node:perf_hooks');
const root = path.resolve(__dirname, '..');
const fixtures = path.join(root, '_build/browser-acceptance');
const playwrightPath = process.env.MOONSQLITE_PLAYWRIGHT || 'playwright';
const playwright = require(playwrightPath);
assert.equal(require(path.join(playwrightPath, 'package.json')).version, JSON.parse(fs.readFileSync(path.join(root, 'tools/toolchain.json'), 'utf8')).playwright);
const baseline = process.argv.includes('--baseline');
function processMemory(ids) {
  if (process.platform === 'win32') {
    // 切换 Worker 后部分 PID 已退出；保留存活进程的采样，不让该预期缺失污染命令退出码。
    const command = `$scaleProcesses = @(Get-Process -Id ${ids.join(',')} -ErrorAction SilentlyContinue); if (!$scaleProcesses.Count) { throw 'No live acceptance browser processes' }; $scaleProcesses | Select-Object Id,WorkingSet64,PeakWorkingSet64 | ConvertTo-Json -Compress; exit 0`;
    const data = JSON.parse(execFileSync('powershell.exe', ['-NoProfile', '-Command', command], {encoding: 'utf8'}));
    return (Array.isArray(data) ? data : [data]).map(item => ({pid: item.Id, rss_bytes: item.WorkingSet64, peak_rss_bytes: item.PeakWorkingSet64}));
  }
  assert.equal(process.platform, 'linux', '内存验收目前支持 Windows/Linux');
  return ids.flatMap(pid => {
    try { const status = fs.readFileSync(`/proc/${pid}/status`, 'utf8');
      return [{pid, rss_bytes: Number(/^VmRSS:\s+(\d+)/m.exec(status)[1])*1024,
        peak_rss_bytes: Number(/^VmHWM:\s+(\d+)/m.exec(status)[1])*1024}]; }
    catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  });
}
async function scenario(file, cancel = false) {
  const html = fs.readFileSync(path.join(root, baseline ? '_build/viewer-stress/baseline.html' : '_build/pages/index.html'));
  const server = http.createServer((request, response) => { response.setHeader('Content-Type', 'text/html; charset=utf-8'); response.end(html); });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const browser = await playwright.chromium.launch({headless: true, ...(process.env.MOONSQLITE_BROWSER ? {executablePath: process.env.MOONSQLITE_BROWSER} : {})});
  try {
    const session = await browser.newBrowserCDPSession();
    async function memory() { const data = await session.send('SystemInfo.getProcessInfo');
      const processes = processMemory(data.processInfo.map(item => item.id));
      assert(processes.length > 0); return {processes, rss_bytes: processes.reduce((sum, item) => sum+item.rss_bytes, 0),
        sum_process_peak_rss_bytes: processes.reduce((sum, item) => sum+item.peak_rss_bytes, 0)}; }
    const page = await browser.newPage();
    await page.addInitScript(() => {
      window.scaleMessages = [];
      window.scaleWorkers = {created: 0, terminated: 0, closed: []};
      const Original = window.Worker;
      window.Worker = class extends Original { constructor(...args) { super(...args);
        window.scaleWorkers.created++;
        this.addEventListener('message', ({data}) => { if (data.closed) window.scaleWorkers.closed.push(data.handles); if (!data.result) return;
          const result = data.result;
          const characters = result.records?.reduce((total, record) => total+record.values.reduce((sum, value) => sum+String(value.value).length, 0), 0);
          window.scaleMessages.push({records: result.records?.length, fields: result.records?.map(record => record.values.length),
            characters,
            // 大消息基线只计字符，避免测量工具自己再复制整批大值。
            message_bytes: characters === undefined || characters <= 262144 ? new TextEncoder().encode(JSON.stringify(data)).length : null, display: result.display,
            reason: result.reason ?? result.result?.reason, progress: result.progress,
            rowids: result.records?.map(record => record.rowid), io: result.io, budgets: result.export?.budgets});
        }); }
        terminate() { window.scaleWorkers.terminated++; return super.terminate(); }
      };
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.locator('#file').setInputFiles(path.join(fixtures, file));
    await page.waitForFunction(() => document.querySelector('#status').dataset.state === 'ready');
    const initial = await memory(), started = performance.now();
    if (typeof cancel === 'string') {
      await page.locator('#objects').selectOption('2'); await page.locator('#preview-batch').fill('8');
      await page.locator('#preview-start').click();
      await page.waitForFunction(() => document.querySelector('#preview-status').textContent.includes('正在读取原始记录'));
      const actionAt = performance.now();
      if (cancel.endsWith('budget-during-preview')) {
        const opening = cancel.startsWith('open-');
        if (opening) await page.getByText('检查预算', {exact: true}).click();
        await page.locator(opening ? '#max-rows' : '#preview-limit').fill('3');
        await page.waitForFunction(() => window.scaleMessages.some(result => result.records > 0));
        assert(await page.locator('#preview-next').isDisabled(), '操作中改变预算后，晚到结果不能重新启用续读');
        assert((await page.locator('#preview-status').textContent()).includes(opening ? '重新读取对象' : '重新预览'));
        const result = await page.evaluate(() => window.scaleMessages.findLast(item => item.records !== undefined));
        assert.equal(result.budgets.requested_limit, 200); assert.equal(result.budgets.max_rows, 100000);
        if (opening) assert(await page.locator('#preview-start').isDisabled());
        else assert(!await page.locator('#preview-start').isDisabled());
        return {file, operation: cancel, result, baseline: initial, final: await memory()};
      }
      if (cancel === 'preview-cancel') {
        await page.locator('#cancel').click();
        await page.waitForFunction(() => window.scaleMessages.some(result => result.records !== undefined && result.reason === 'cancelled'));
        const result = await page.evaluate(() => window.scaleMessages.findLast(item => item.records !== undefined));
        assert.equal(result.reason, 'cancelled');
        const cancellation_ms = performance.now()-actionAt; assert(cancellation_ms < 10000);
        return {file, operation: cancel, cancellation_ms, baseline: initial, final: await memory(), result};
      }
      const selector = cancel === 'switch-db' ? '#file' : '#wal-file';
      const selected = cancel === 'switch-db' ? path.join(root, 'fixtures/empty.sqlite') : path.join(fixtures, 'preview-switch.wal');
      await page.locator(selector).setInputFiles(selected);
      await page.waitForFunction(() => document.querySelector('#status').dataset.state === 'ready' && document.querySelector('#cancel').disabled);
      await page.waitForFunction(() => window.scaleWorkers.created-window.scaleWorkers.terminated === 1);
      const workers = await page.evaluate(() => window.scaleWorkers);
      for (const handles of workers.closed) assert(Object.values(handles).every(value => value === 0));
      assert.equal(await page.locator('#records article').count(), 0);
      assert((await page.locator('#files').textContent()).includes(cancel === 'switch-db' ? 'empty.sqlite' : 'preview-switch.wal'));
      if (cancel === 'switch-wal') {
        await page.locator('#objects').selectOption('2'); await page.locator('#preview-start').click();
        await page.waitForFunction(() => window.scaleMessages.filter(item => item.records > 0).length > 0);
        assert.equal((await page.evaluate(() => window.scaleMessages.findLast(item => item.io))).io.handles.indexes, 1);
      }
      return {file, operation: cancel, switch_ms: performance.now()-actionAt, workers, baseline: initial, final: await memory()};
    }
    if (cancel) {
      await page.locator('#start').click();
      await page.waitForFunction(() => document.querySelector('#status').textContent.includes('正在检查：'));
      const cancelled = performance.now(); await page.locator('#cancel').click();
      await page.waitForFunction(() => document.querySelector('#status').dataset.state === 'incomplete' && document.querySelector('#cancel').disabled);
      const cancellation_ms = performance.now()-cancelled;
      const result = await page.evaluate(() => window.scaleMessages.findLast(item => item.io));
      assert.equal(result.reason, 'cancelled'); assert(cancellation_ms < 10000);
      return {file, cancelled: true, cancellation_ms, seconds: (performance.now()-started)/1000, baseline: initial, final: await memory(), result};
    }
    await page.locator('#objects').selectOption('2'); await page.locator('#preview-batch').fill('8');
    if (!baseline) await page.locator('#value-limit').fill(file.startsWith('wide') ? '4096' : '256');
    await page.locator('#preview-start').click();
    await page.waitForFunction(() => window.scaleMessages.some(result => result.records > 0), null, {timeout: 180000});
    const result = await page.evaluate(() => window.scaleMessages.find(item => item.records > 0));
    if (!baseline) {
      assert(result.characters <= 262144); assert(result.fields.every(count => count <= 128));
      assert(result.message_bytes < 2*1024*1024);
      if (file.startsWith('wide')) { assert(result.display.paused_at_display_budget); assert.equal(result.records, 1); }
      else {
        assert.equal(result.records, 1); assert(result.display.paused_at_payload_threshold);
        await page.locator('#preview-next').click();
        await page.waitForFunction(() => window.scaleMessages.filter(item => item.records > 0).length === 2);
        const second = await page.evaluate(() => window.scaleMessages.filter(item => item.records > 0)[1]);
        assert.equal(second.records, 1); assert(second.characters <= 262144);
        assert.notDeepEqual(second.rowids, result.rowids);
      }
      assert.equal(await page.locator('#records article').count(), result.records);
    }
    return {file, baseline_transport: baseline, seconds: (performance.now()-started)/1000, baseline: initial, final: await memory(), result};
  } finally { await browser.close(); await new Promise(done => server.close(done)); }
}
(async () => {
  const results = [];
  for (const file of baseline ? ['blob-batch.sqlite'] : ['blob-batch.sqlite', 'wide-records.sqlite', 'hundred-mib.sqlite']) {
    const result = await scenario(file, file === 'hundred-mib.sqlite'); results.push(result); console.log(JSON.stringify(result));
  }
  const operations = process.env.MOONSQLITE_SCALE_OPERATION ? [process.env.MOONSQLITE_SCALE_OPERATION] :
    ['preview-cancel', 'switch-db', 'switch-wal', 'budget-during-preview', 'open-budget-during-preview'];
  if (!baseline) for (const operation of operations) {
    const result = await scenario(operation === 'switch-wal' ? 'preview-switch.db' : operation.endsWith('budget-during-preview') ? 'blob-batch.sqlite' : 'hundred-mib.sqlite', operation);
    results.push(result); console.log(JSON.stringify(result));
  }
  fs.writeFileSync(path.join(root, baseline ? '_build/browser-scale-baseline.json' : '_build/browser-scale-acceptance.json'), JSON.stringify({
    platform: process.platform, memory_measurement: 'OS RSS after operation and sum of per-process lifetime RSS high-water marks; peaks need not coincide', results}, null, 2)+'\n', 'utf8');
})().catch(error => { console.error(error); process.exitCode = 1; });
