'use strict';
// 所有格式解析都在隔离 worker 中调用编译后的 MoonBit；主线程仅展示已有报告。
const parserSource = JSON.parse(document.getElementById('parser-source').textContent);
const workerSource = `self.onmessage = function(event) {
  let exitCode = 0;
  globalThis.moonsqlitefileHost = {
    args: event.data.args, bytes: event.data.bytes,
    exitCode: code => { exitCode = code; },
    output: text => self.postMessage({ result: JSON.parse(text), exitCode }),
    error: message => self.postMessage({ error: message })
  };
  try { ${parserSource}\n } catch (error) { self.postMessage({ error: String(error) }); }
};`;
const workerURL = URL.createObjectURL(new Blob([workerSource], { type: 'text/javascript' }));
const el = id => document.getElementById(id);
const kinds = { btree_root: 'B-tree 根页', btree_child: 'B-tree 子页', overflow_first: '首个 overflow 页', overflow_continuation: '后续 overflow 页', freelist_trunk: 'freelist trunk', freelist_leaf: 'freelist leaf', pointer_map: 'Ptrmap 页', lock_byte: 'lock-byte 页' };
let bytes = null, data = null, selected = 1, rawOffset = 0, generation = 0, pageRequest = 0;
const jobs = new Set();

function run(args, input) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(workerURL);
    const job = { worker, cancel: () => { finish(); reject(new Error("已取消旧检查")); } };
    jobs.add(job);
    const finish = () => { clearTimeout(timer); worker.terminate(); jobs.delete(job); };
    const timer = setTimeout(() => { finish(); reject(new Error('检查超过 30 秒，请使用 CLI 检查此文件。')); }, 30000);
    worker.onmessage = event => { finish(); event.data.error ? reject(new Error(event.data.error)) : resolve(event.data.result); };
    worker.onerror = event => { finish(); reject(new Error(event.message)); };
    worker.postMessage({ args: ['local.sqlite', ...args], bytes: input });
  });
}

function cancelJobs() {
  for (const job of [...jobs]) job.cancel();
  jobs.clear();
}

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

async function loadBytes(input, ticket) {
  if (ticket !== generation) return;
  bytes = input;
  data = await run(['viewer-data'], bytes);
  if (ticket !== generation) return;
  renderOverview();
  el('page-number').max = String(data.header.page_count);
  await showPage(1);
}

function beginLoad() {
  const ticket = ++generation;
  pageRequest++;
  cancelJobs();
  data = null; bytes = null;
  el('overview').hidden = true; el('workspace').hidden = true;
  el('status').textContent = '正在检查数据库…';
  el('status').dataset.state = 'loading';
  return ticket;
}

function loadError(error, ticket) {
  if (ticket !== generation) return;
  el('status').textContent = `无法检查此文件：${error.message}`;
  el('status').dataset.state = 'failed';
}

function renderRaw() {
  const size = data.header.page_size, start = (selected - 1) * size;
  rawOffset = Math.max(0, Math.min(size - 1, rawOffset));
  const end = Math.min(size, rawOffset + 256), lines = [];
  for (let offset = rawOffset; offset < end; offset += 16) {
    const chunk = bytes.subarray(start + offset, start + Math.min(offset + 16, end));
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
  cancelJobs();
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
  renderRaw(); renderStatistics(null);
  const type = bytes[(number - 1) * data.header.page_size + (number === 1 ? 100 : 0)];
  if (owner && !['btree_root','btree_child'].includes(owner.kind)) { el('page-status').textContent = '此用途不提供 B-tree 布局统计，可查看原始字节与归属关系。'; return; }
  if (!owner && ![2,5,10,13].includes(type)) { el('page-status').textContent = '无法按 B-tree 类型解释此页，保留原始字节。'; return; }
  el('page-status').textContent = '正在检查页内布局…';
  try {
    const report = await run(['page-inspect', String(number)], bytes);
    if (request !== pageRequest || ticket !== generation) return;
    el('page-status').textContent = report.status === 'complete' ? `页内布局检查完成 · ${report.page.cell_count} 个 cell` : `${report.diagnostic.code}：${report.diagnostic.message}（页内偏移 ${report.diagnostic.byte_offset ?? '未知'}）`;
    renderStatistics(report);
  } catch (error) { if (request === pageRequest && ticket === generation) el('page-status').textContent = error.message; }
}

el('file').onchange = async event => {
  const file = event.target.files[0]; if (!file) return;
  const ticket = beginLoad();
  try { if (file.size > 64 * 1024 * 1024) throw new Error('演示文件上限为 64 MiB，请使用 CLI。'); await loadBytes(new Uint8Array(await file.arrayBuffer()), ticket); }
  catch (error) { loadError(error, ticket); }
  event.target.value = '';
};
el('demo').onclick = async () => {
  const ticket = beginLoad();
  try { const base64 = JSON.parse(el('demo-bytes').textContent); await loadBytes(Uint8Array.from(atob(base64), char => char.charCodeAt(0)), ticket); }
  catch (error) { loadError(error, ticket); }
};
el('objects').onchange = event => { if (event.target.value) showPage(Number(event.target.value)); };
el('go').onclick = () => showPage(Number(el('page-number').value));
el('page-number').onkeydown = event => { if (event.key === 'Enter') showPage(Number(event.target.value)); };
el('previous').onclick = () => showPage(selected - 1); el('next').onclick = () => showPage(selected + 1);
el('cells').onchange = event => { rawOffset = Number(event.target.value); renderRaw(); };
el('raw-previous').onclick = () => { rawOffset = Math.max(0, rawOffset - 256); renderRaw(); };
el('raw-next').onclick = () => { rawOffset += 256; renderRaw(); };
