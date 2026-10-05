'use strict';
// 所有格式解析都在隔离 worker 中调用编译后的 MoonBit；主线程仅展示已有报告。
const parserSource = JSON.parse(document.getElementById('parser-source').textContent);
const workerSource = parserSource + '\n' + JSON.parse(document.getElementById('worker-source').textContent);
const workerURL = URL.createObjectURL(new Blob([workerSource], {type: 'text/javascript'}));
const el = id => document.getElementById(id);
const kinds = {btree_root: 'B-tree 根页', btree_child: 'B-tree 子页', overflow_first: '首个 overflow 页', overflow_continuation: '后续 overflow 页', freelist_trunk: 'freelist trunk', freelist_leaf: 'freelist leaf', pointer_map: 'Ptrmap 页', lock_byte: 'lock-byte 页'};
let bytes = null, data = null, selected = 1, rawOffset = 0, generation = 0, pageRequest = 0;
let file = null, walFile = null, worker = null, serial = 0;
const jobs = new Map();
function run(message, progress) {
  const id = ++serial, active = worker;
  return new Promise((resolve, reject) => {
    jobs.set(id, {worker: active, resolve, reject, progress});
    active.postMessage({...message, id});
  });
}
function createWorker() {
  const active = new Worker(workerURL);
  active.onmessage = ({data: response}) => {
    const job = jobs.get(response.id);
    if (!job || job.worker !== active) return;
    if (response.progress) { job.progress?.(response.progress); return; }
    jobs.delete(response.id);
    if (response.error) job.reject(new Error(response.error.message));
    else job.resolve(response.closed ? response : response.result);
  };
  active.onerror = event => {
    for (const [id, job] of jobs) if (job.worker === active) {
      jobs.delete(id); job.reject(new Error(event.message));
    }
  };
  return active;
}
function closeWorker(active) {
  if (!active) return;
  const id = ++serial;
  let timer;
  const release = () => { clearTimeout(timer); jobs.delete(id); active.terminate(); };
  jobs.set(id, {worker: active, resolve: release, reject: release});
  active.postMessage({op: 'close', id});
  timer = setTimeout(release, 1000);
  for (const [pendingId, job] of jobs) if (pendingId !== id && job.worker === active) {
    jobs.delete(pendingId); job.reject(new Error('已切换文件'));
  }
}
window.addEventListener('pagehide', () => { worker?.terminate(); URL.revokeObjectURL(workerURL); });

function textNode(tag, text, className) {
  const node = document.createElement(tag);
  node.textContent = text;
  if (className) node.className = className;
  return node;
}

function pageButton(label, page, offset = 0) {
  const button = textNode('button', label);
  button.disabled = !Number.isInteger(page) || page < 1 || page > data.header.page_count;
  button.onclick = () => showPage(page, offset);
  return button;
}

function renderOverview() {
  const report = data.inspection, summary = data.summary;
  const names = { complete: '检查范围已完成', incomplete: '检查未完成', failed: '检查发现失败' };
  el('status').textContent = `${names[report.status]} · 当前结果仅覆盖已实现的结构检查`;
  el('status').dataset.state = report.status;
  el('metrics').replaceChildren();
  for (const [label, value] of [['逻辑页数', data.header.page_count], ['页大小 / 字节', data.header.page_size], ['已认领页', summary.claimed_pages], ['已解码记录', report.records_decoded]]) {
    const node = textNode('div', '', 'metric');
    node.append(textNode('small', label), textNode('strong', String(value)));
    el('metrics').append(node);
  }
  el('scope').textContent = `页归属：${report.ownership_complete ? '遍历已完成' : '未完成，统计为已观察结果'}；Ptrmap：${report.ptrmap_checked ? '已核对或不适用' : '未完成'}；诊断：${report.diagnostics_truncated ? '已截断' : '未截断'}；已枚举未认领页：${summary.unclaimed_pages}。`;
  el('objects').replaceChildren(textNode('option', '选择对象…'));
  el('objects').firstChild.value = '';
  for (const object of summary.objects) {
    const option = textNode('option', `${object.object_name ?? '未命名'} · 根页 ${object.root_page} · ${object.btree_pages + object.overflow_pages} 页`);
    option.value = String(object.root_page);
    el('objects').append(option);
  }
  el('kinds').replaceChildren();
  for (const item of summary.page_kinds.filter(item => item.pages)) {
    const row = textNode('div', '', 'kind-row');
    row.append(textNode('span', kinds[item.kind] || item.kind), textNode('strong', String(item.pages)));
    el('kinds').append(row);
  }
  el('issues').replaceChildren();
  report.issues.forEach((issue, index) => {
    const node = textNode('div', issue.message || ({page_conflict: '页面归属冲突', unclaimed_page: '归属遍历完成后仍未认领', ptrmap_mismatch: 'Ptrmap 与观察归属不一致'}[issue.code] || issue.code), 'issue');
    const location = data.locations[index];
    const number = location?.page_number ?? issue.page_number ?? issue.first?.page_number;
    if (number != null) node.append(pageButton(`页 ${number}${location?.byte_offset == null ? '' : ` · 偏移 ${location.byte_offset}`}`, number, location?.byte_offset ?? 0));
    el('issues').append(node);
  });
  if (!report.issues.length) el('issues').append(textNode('p', report.status === 'complete' ? '当前检查范围内没有诊断。' : '检查未完成；暂无已保存诊断。', 'empty'));
  el('overview').hidden = false;
  el('workspace').hidden = false;
}

function budget(id) {
  const input = el(id), value = Number(input.value);
  if (!input.checkValidity() || !Number.isInteger(value)) throw new Error('检查预算必须为范围内的整数');
  return value;
}
async function loadFiles() {
  if (!file) return;
  const ticket = beginLoad();
  try {
    const pages = budget('max-pages'), rows = budget('max-rows');
    data = await run({op: 'open', file, wal: walFile, timeout: budget('timeout'), options: {
      max_pages: pages, max_report_pages: pages, max_rows: rows,
      max_total_payload_bytes: String(BigInt(budget('max-payload')) * 1048576n),
      tailPolicy: el('wal-prefix').checked ? 'valid_prefix' : 'strict', cachePages: 256,
    }}, progress => {
      if (ticket !== generation) return;
      el('status').textContent = progress.phase === 'wal'
        ? `正在校验 WAL：${progress.frames_read} 帧…`
        : `正在检查：${progress.pages_read} 页，${progress.records_read} 条记录，payload ${progress.payload_bytes} 字节…`;
    });
    if (ticket !== generation) return;
    renderOverview();
    el('scope').textContent += ` 数据库实际读取 ${data.io.db.bytes} 字节 / ${data.io.db.reads} 次（最大块 ${data.io.db.maxRead}）；${data.wal ? `WAL ${data.wal.committed_frames} 已提交帧，实际读取 ${data.io.wal.bytes} 字节。` : '未配对 WAL。'}`;
    if (data.reason) el('status').textContent += ` · ${data.reason === 'cancelled' ? '已取消或达到时间预算，保留部分结果' : data.reason}`;
    el('page-number').max = String(data.header.page_count);
    await showPage(1);
  } catch (error) { loadError(error, ticket); }
  finally { if (ticket === generation) el('cancel').disabled = true; }
}
function beginLoad() {
  const ticket = ++generation;
  pageRequest++;
  closeWorker(worker); worker = createWorker();
  data = null; bytes = null;
  el('overview').hidden = true; el('workspace').hidden = true;
  el('status').textContent = '正在检查数据库…'; el('status').dataset.state = 'loading';
  el('cancel').disabled = false; el('start').disabled = !file;
  el('files').textContent = `${file.name || '示例库'}${walFile ? ` + ${walFile.name}` : ''}`;
  return ticket;
}

function loadError(error, ticket) {
  if (ticket !== generation) return;
  el('status').textContent = `无法检查此文件：${error.message}`;
  el('status').dataset.state = 'failed';
}

function renderRaw() {
  if (!bytes) return;
  const size = data.header.page_size;
  rawOffset = Math.max(0, Math.min(size - 1, rawOffset));
  const end = Math.min(size, rawOffset + 256), lines = [];
  for (let offset = rawOffset; offset < end; offset += 16) {
    const chunk = bytes.subarray(offset, Math.min(offset + 16, end));
    const hex = [...chunk].map(byte => byte.toString(16).padStart(2, '0')).join(' ').padEnd(47);
    const ascii = [...chunk].map(byte => byte >= 32 && byte <= 126 ? String.fromCharCode(byte) : '.').join('');
    lines.push(`${offset.toString(16).padStart(4, '0')}  ${hex}  ${ascii}`);
  }
  el('raw').textContent = lines.join('\n');
  el('raw-previous').disabled = rawOffset === 0;
  el('raw-next').disabled = end === size;
}

function renderStatistics(report) {
  el('space').replaceChildren(); el('statistics').replaceChildren(); el('cells').replaceChildren();
  el('cells').disabled = !report?.page?.cell_offsets.length;
  if (!report?.statistics) return;
  const stats = report.statistics, size = data.header.page_size;
  const parts = [['database_header_bytes','文件头','#183e58'],['btree_header_bytes','页头','#316888'],['pointer_bytes','指针数组','#4b92af'],['unallocated_bytes','未分配区','#d2e5ee'],['cell_bytes','cell','#179b8d'],['freeblock_bytes','freeblock','#edb76b'],['fragmented_bytes','碎片','#d48070'],['reserved_bytes','保留区','#9a91bd']];
  const legend = textNode('div', '', 'legend');
  for (const [key, label, color] of parts) {
    if (!stats[key]) continue;
    const segment = textNode('span', '');
    segment.style.width = `${stats[key] / size * 100}%`; segment.style.background = color; segment.title = `${label}：${stats[key]} 字节`;
    el('space').append(segment);
    const item = textNode('span', `${label} ${stats[key]}`), dot = textNode('i', ''); dot.style.background = color; item.prepend(dot); legend.append(item);
  }
  el('statistics').append(legend, textNode('p', `cell 声明 payload：${stats.payload_bytes} 字节；页内 payload：${stats.local_payload_bytes} 字节；需要 overflow 的 cell：${stats.overflow_cells}。此页报告不验证外部链或 record 内容。`, 'payload'));
  report.page.cell_offsets.forEach((offset, index) => { const option = textNode('option', `cell ${index} · ${offset}`); option.value = String(offset); el('cells').append(option); });
}

async function showPage(number, offset = 0) {
  if (!data || !Number.isInteger(number) || number < 1 || number > data.header.page_count) return;
  const request = ++pageRequest, ticket = generation;
  selected = number; rawOffset = offset;
  el('page-title').textContent = `页面 ${number}`; el('page-number').value = String(number);
  el('previous').disabled = number === 1; el('next').disabled = number === data.header.page_count;
  const owner = data.inspection.pages.find(page => page.page_number === number);
  el('owner').textContent = owner ? `${kinds[owner.kind] || owner.kind}${owner.object_name == null ? '' : ` · ${owner.object_name}`} · 根页 ${owner.root_page ?? '—'}` : '尚未认领的页；未完成检查时不推断其用途。';
  el('links').replaceChildren();
  if (owner?.parent_page != null) el('links').append(pageButton(`父页 ${owner.parent_page}`, owner.parent_page));
  if (owner?.root_page && owner.root_page !== number) el('links').append(pageButton(`根页 ${owner.root_page}`, owner.root_page));
  for (const child of data.inspection.pages.filter(page => page.parent_page === number)) el('links').append(pageButton(`${kinds[child.kind] || child.kind} ${child.page_number}`, child.page_number));
  bytes = null; el('raw').textContent = ''; renderStatistics(null);
  el('page-status').textContent = '正在读取和检查页内布局…';
  try {
    const result = await run({op: 'page', page: number, kind: owner?.kind});
    if (request !== pageRequest || ticket !== generation) return;
    bytes = result.bytes; renderRaw();
    const report = result.report;
    el('page-status').textContent = !report ? '此用途不提供 B-tree 布局统计，可查看原始字节与归属关系。'
      : report.status === 'complete' ? `页内布局检查完成 · ${report.page.cell_count} 个 cell`
      : `${report.diagnostic.code}：${report.diagnostic.message}（页内偏移 ${report.diagnostic.byte_offset ?? '未知'}）`;
    renderStatistics(report);
  } catch (error) { if (request === pageRequest && ticket === generation) el('page-status').textContent = error.message; }
}

el('file').onchange = event => {
  const selectedFile = event.target.files[0]; if (!selectedFile) return;
  file = selectedFile; walFile = null; el('wal-file').value = ''; loadFiles();
};
el('wal-file').onchange = event => { walFile = event.target.files[0] || null; if (file) loadFiles(); };
el('start').onclick = loadFiles;
el('cancel').onclick = () => { worker?.postMessage({op: 'cancel'}); el('cancel').disabled = true; };
el('demo').onclick = () => {
  const base64 = JSON.parse(el('demo-bytes').textContent);
  file = new File([Uint8Array.from(atob(base64), char => char.charCodeAt(0))], '示例库.sqlite');
  walFile = null; el('file').value = ''; el('wal-file').value = ''; loadFiles();
};
el('objects').onchange = event => { if (event.target.value) showPage(Number(event.target.value)); };
el('go').onclick = () => showPage(Number(el('page-number').value));
el('page-number').onkeydown = event => { if (event.key === 'Enter') showPage(Number(event.target.value)); };
el('previous').onclick = () => showPage(selected - 1); el('next').onclick = () => showPage(selected + 1);
el('cells').onchange = event => { rawOffset = Number(event.target.value); renderRaw(); };
el('raw-previous').onclick = () => { rawOffset = Math.max(0, rawOffset - 256); renderRaw(); };
el('raw-next').onclick = () => { rawOffset += 256; renderRaw(); };
