'use strict';
// 所有格式解析都在隔离 worker 中调用编译后的 MoonBit；主线程仅展示已有报告。
const parserSource = JSON.parse(document.getElementById('parser-source').textContent);
const workerSource = parserSource + '\n' + JSON.parse(document.getElementById('worker-source').textContent);
let workerURL = null;
const el = id => document.getElementById(id);
const kinds = {btree_root: 'B-tree 根页', btree_child: 'B-tree 子页', overflow_first: '首个 overflow 页', overflow_continuation: '后续 overflow 页', freelist_trunk: 'freelist trunk', freelist_leaf: 'freelist leaf', pointer_map: 'Ptrmap 页', lock_byte: 'lock-byte 页'};
const reasons = {complete: '已读完当前范围', record_limit: '达到累计记录上限', visitor_stopped: '读取已停止',
  preview_paused: '游标已暂停，可继续读取', limit_exceeded: '资源预算已用尽', cancelled: '操作已取消',
  host_failure: '宿主读取或回调失败', short_read: '文件读取不完整', range_out_of_bounds: '读取范围越界',
  invalid: '发现格式或结构损坏', unsupported: '当前范围暂不支持'};
const objectTypes = {table: '表', index: '索引', view: '视图', trigger: '触发器'};
let bytes = null, data = null, selected = 1, rawOffset = 0, generation = 0, pageRequest = 0;
let file = null, walFile = null, worker = null, serial = 0;
let owners = new Map(), children = new Map(), previewReport = null, previewRoot = null, previewRequest = 0;
let objectChoices = new Map(), openingBudgetChanged = false;
const jobs = new Map();
function run(message, progress) {
  const id = ++serial, active = worker;
  return new Promise((resolve, reject) => {
    jobs.set(id, {worker: active, resolve, reject, progress});
    active.postMessage({...message, id});
  });
}
function createWorker() {
  if (!workerURL) workerURL = URL.createObjectURL(new Blob([workerSource], {type: 'text/javascript'}));
  const active = new Worker(workerURL);
  active.onmessage = ({data: response}) => {
    const job = jobs.get(response.id);
    if (!job || job.worker !== active) return;
    if (response.progress) { job.progress?.(response.progress); return; }
    jobs.delete(response.id);
    if (response.error) job.reject(Object.assign(new Error(response.error.message), response.error));
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
window.addEventListener('pagehide', () => {
  generation++; pageRequest++; previewRequest++;
  for (const [id, job] of jobs) { jobs.delete(id); job.reject(new Error('页面已离开，返回后重新打开静态副本')); }
  worker?.terminate(); worker = null;
  if (workerURL) URL.revokeObjectURL(workerURL); workerURL = null;
});
window.addEventListener('pageshow', event => { if (event.persisted && file) loadFiles(false); });

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
  owners = new Map(report.pages.map(page => [page.page_number, page])); children = new Map();
  for (const page of report.pages) if (page.parent_page != null) {
    if (!children.has(page.parent_page)) children.set(page.parent_page, []);
    children.get(page.parent_page).push(page);
  }
  const names = { complete: '检查范围已完成', incomplete: '检查未完成', failed: '检查发现失败' };
  el('status').textContent = `${names[report.status]} · 当前结果仅覆盖已实现的结构检查`;
  el('status').dataset.state = report.status;
  const advice = {corruption: '发现结构损坏，请查看诊断位置', source: '读取失败，请重新选择不可变副本', budget: '预算不足，可提高预算后重试', cancelled: '已取消，可重新检查', unsupported: '当前版本不支持该能力', argument: '请修正输入参数'};
  const categories = [...new Set(data.export.diagnostics.map(item => item.category))];
  if (categories.length) el('status').textContent += ` · ${categories.map(category => advice[category]).join('；')}`;
  el('metrics').replaceChildren();
  for (const [label, value] of [['逻辑页数', data.header.page_count], ['页大小 / 字节', data.header.page_size], ['已认领页', summary.claimed_pages], ['已解码记录', report.records_decoded]]) {
    const node = textNode('div', '', 'metric');
    node.append(textNode('small', label), textNode('strong', String(value)));
    el('metrics').append(node);
  }
  el('scope').textContent = `页归属：${report.ownership_complete ? '遍历已完成' : '未完成，统计为已观察结果'}；Ptrmap：${report.ptrmap_checked ? '已核对或不适用' : '未完成'}；诊断：${report.diagnostics_truncated ? '已截断' : '未截断'}；已枚举未认领页：${summary.unclaimed_pages}。`;
  renderObjects(data.schema?.entries ?? summary.objects.map(object => ({name: object.object_name ?? '未命名', root_page: object.root_page, object_type: '对象'})));
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
  el('preview-panel').hidden = false;
  el('export').disabled = false;
}

function renderSchema() {
  const schema = data.schema;
  el('status').dataset.state = schema.status === 'failed' ? 'failed' : 'ready';
  el('status').textContent = schema.status === 'complete' ? '对象读取完成；尚未运行完整结构检查。' : `对象列表仅为已读取前缀 · ${reasons[schema.reason] ?? '读取未完成'}。可调整预算或重新选择静态副本后重试。`;
  el('metrics').replaceChildren(textNode('p', `逻辑页数 ${data.header.page_count} · 页大小 ${data.header.page_size} 字节 · 已读取对象 ${schema.entries.length}`));
  el('scope').textContent = `对象列表：${schema.status === 'complete' ? '完整' : '仅已读取前缀'}；完整结构检查尚未运行。`;
  if (data.export.budgets.limit !== data.export.budgets.requested_limit) el('scope').textContent += ` 对象上限受最多记录限制为 ${data.export.budgets.limit}。`;
  renderObjects(schema.entries);
  el('kinds').replaceChildren(); el('issues').replaceChildren(textNode('p', '全库页归属与诊断将在主动检查后显示。'));
  if (schema.error) el('issues').append(textNode('p', `${reasons[schema.error.kind] ?? '对象读取失败'}：${schema.error.message}`, 'issue'));
  el('overview').hidden = false; el('workspace').hidden = false; el('preview-panel').hidden = false; el('export').disabled = false;
}
function renderObjects(entries) {
  objectChoices = new Map();
  el('objects').replaceChildren(textNode('option', '选择对象…')); el('objects').firstChild.value = '';
  entries.forEach((entry, index) => {
    const type = objectTypes[entry.object_type] ?? entry.object_type;
    const option = textNode('option', `${entry.name} · ${type} · 根页 ${entry.root_page}`);
    option.value = entry.root_page > 0 ? String(entry.root_page) : `schema:${index}`;
    if (entry.root_page === 0) option.textContent = `${entry.name} · ${type} · 无根页`;
    objectChoices.set(option.value, entry); el('objects').append(option);
  });
  el('object-info').textContent = '选择表或索引浏览根页和原始记录。';
  el('object-definition').hidden = true; el('preview-start').disabled = true;
}
function canPreview() {
  return !openingBudgetChanged && (objectChoices.get(el('objects').value)?.root_page ?? 0) > 0;
}
function showObject() {
  const entry = objectChoices.get(el('objects').value);
  el('preview-start').disabled = !canPreview();
  el('object-definition').hidden = !entry?.sql;
  el('object-sql').textContent = entry?.sql ? entry.sql.slice(0, 4096) + (entry.sql.length > 4096 ? '\n…仅展示前 4096 字符' : '') : '';
  el('object-info').textContent = !entry ? '选择表或索引浏览根页和原始记录。' : entry.root_page > 0
    ? `${entry.name} · ${entry.object_type} · 根页 ${entry.root_page}`
    : `${entry.name} 没有 B-tree 根页，仅展示 schema 信息；view、trigger 和无根页表不能直接预览记录。虚拟表语义不在本工具检查范围。`;
  if (entry?.root_page > 0) showPage(entry.root_page);
}

function budget(id) {
  const input = el(id), value = Number(input.value);
  if (!input.checkValidity() || !Number.isInteger(value)) throw new Error('检查预算必须为范围内的整数');
  return value;
}
async function loadFiles(check = false) {
  if (!file) return;
  const ticket = beginLoad();
  try {
    const pages = budget('max-pages'), rows = budget('max-rows');
    data = await run({op: 'open', file, wal: walFile, check, schemaLimit: budget('schema-limit'), timeout: budget('timeout'), options: {
      max_pages: pages, max_report_pages: pages, max_rows: rows,
      max_total_payload_bytes: String(BigInt(budget('max-payload')) * 1048576n),
      tailPolicy: el('wal-prefix').checked ? 'valid_prefix' : 'strict', cachePages: 256,
    }}, progress => {
      if (ticket !== generation) return;
      el('status').textContent = progress.phase === 'wal'
        ? `正在校验 WAL：${progress.frames_read} 帧…`
        : `正在${check ? '检查' : '读取 schema'}：${progress.pages_read} 页，${progress.records_read} 条记录，payload ${progress.payload_bytes} 字节…`;
    });
    if (ticket !== generation) return;
    if (data.inspection) renderOverview(); else renderSchema();
    el('scope').textContent += ` 数据库实际读取 ${data.io.db.bytes} 字节 / ${data.io.db.reads} 次（最大块 ${data.io.db.maxRead}）；${data.wal ? `WAL ${data.wal.committed_frames} 已提交帧，实际读取 ${data.io.wal.bytes} 字节。` : '未配对 WAL。'}`;
    if (data.reason) el('status').textContent += ` · ${reasons[data.reason] ?? '当前范围未完成'}，保留已观察结果`;
    el('page-number').max = String(data.header.page_count);
    await showPage(1);
  } catch (error) { loadError(error, ticket); }
  finally { if (ticket === generation) { el('cancel').disabled = true; el('start').disabled = false; el('open').disabled = false; } }
}
function beginLoad() {
  const ticket = ++generation;
  pageRequest++;
  previewRequest++; previewReport = null; previewRoot = null; owners = new Map(); children = new Map();
  closeWorker(worker); worker = createWorker();
  data = null; bytes = null;
  el('overview').hidden = true; el('workspace').hidden = true;
  el('preview-panel').hidden = true; el('records').replaceChildren(); el('preview-next').disabled = true;
  openingBudgetChanged = false;
  el('objects').disabled = false; el('preview-start').disabled = true;
  el('export').disabled = true; el('preview-export').disabled = true;
  el('status').textContent = '正在检查数据库…'; el('status').dataset.state = 'loading';
  el('cancel').disabled = false; el('start').disabled = true; el('open').disabled = true;
  el('files').textContent = `${file.name || '示例库'}${walFile ? ` + ${walFile.name}` : ''}`;
  return ticket;
}

function loadError(error, ticket) {
  if (ticket !== generation) return;
  const names = {argument: '参数不符合要求', corruption: '文件格式损坏', source: '文件读取失败', budget: '预算不足', cancelled: '操作已取消', unsupported: '暂不支持此能力'};
  el('status').textContent = `${names[error.category] ?? '无法检查此文件'}：${error.message}。可调整预算或重新选择静态副本后重试。`;
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
  const owner = owners.get(number);
  el('owner').textContent = owner ? `${kinds[owner.kind] || owner.kind}${owner.object_name == null ? '' : ` · ${owner.object_name}`} · 根页 ${owner.root_page ?? '—'}` : '尚未认领的页；未完成检查时不推断其用途。';
  el('links').replaceChildren();
  if (owner?.parent_page != null) el('links').append(pageButton(`父页 ${owner.parent_page}`, owner.parent_page));
  if (owner?.root_page && owner.root_page !== number) el('links').append(pageButton(`根页 ${owner.root_page}`, owner.root_page));
  for (const child of children.get(number) ?? []) el('links').append(pageButton(`${kinds[child.kind] || child.kind} ${child.page_number}`, child.page_number));
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
el('start').onclick = () => loadFiles(true);
el('open').onclick = () => loadFiles(false);
el('cancel').onclick = () => { worker?.postMessage({op: 'cancel'}); el('cancel').disabled = true; };
el('demo').onclick = () => {
  const base64 = JSON.parse(el('demo-bytes').textContent);
  file = new File([Uint8Array.from(atob(base64), char => char.charCodeAt(0))], '示例库.sqlite');
  walFile = null; el('file').value = ''; el('wal-file').value = ''; loadFiles();
};
el('objects').onchange = event => {
  previewRequest++; previewRoot = null; previewReport = null;
  el('preview-next').disabled = true; el('preview-export').disabled = true;
  el('records').replaceChildren(); el('preview-status').textContent = '';
  run({op: 'preview-close'}).catch(() => {});
  showObject();
};
function download(report) {
  if (!report) return;
  const url = URL.createObjectURL(new Blob([JSON.stringify(report, null, 2)+'\n'], {type: 'application/json'}));
  const link = textNode('a', ''); link.href = url; link.download = `moonsqlitefile-${report.tool_version}-${report.scope}.json`;
  link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}
el('export').onclick = () => download(data?.export);
el('preview-export').onclick = () => download(previewReport);
function previewBudgetsChanged(budgets) {
  try {
    return budget('preview-limit') !== budgets.requested_limit ||
      String(BigInt(budget('max-payload')) * 1048576n) !== budgets.max_total_payload_bytes ||
      budget('timeout') !== budgets.timeout_seconds;
  } catch { return true; }
}
async function showRecords(reset) {
  const ticket = generation, request = ++previewRequest;
  el('preview-start').disabled = true; el('preview-next').disabled = true; el('cancel').disabled = false;
  el('objects').disabled = true;
  try {
    const root = reset ? Number(el('objects').value) : previewRoot;
    if (!Number.isInteger(root) || root < 1) throw new Error('请先选择有根页的对象');
    const valueLimit = budget('value-limit');
    if (reset) { previewRoot = root; el('records').replaceChildren(); }
    el('preview-status').textContent = '正在读取原始记录…';
    const result = await run({op: 'preview', reset, root, batch: budget('preview-batch'), limit: budget('preview-limit'),
      payload: String(BigInt(budget('max-payload')) * 1048576n), timeout: budget('timeout'), valueLimit});
    if (ticket !== generation || request !== previewRequest) return;
    // 只保留当前批次的 DOM，避免继续读取时累计全部记录与大值。
    if (result.records.length) el('records').replaceChildren();
    for (const record of result.records) {
      const row = textNode('article', '', 'record');
      row.append(textNode('strong', `rowid ${record.rowid ?? '无'} · 页 ${record.page_number} · cell 偏移 ${record.cell_offset}`));
      const values = textNode('ol', '');
      record.values.slice(0, 128).forEach(value => {
        const full = String(value.value), original = value.original_characters ?? full.length, shortened = value.truncated || full.length > valueLimit;
        const displayed = Math.min(full.length, valueLimit);
        values.append(textNode('li', `${value.type}: ${full.slice(0, valueLimit)}${shortened ? `…（仅展示前 ${displayed} 字符，原值 ${original} 字符）` : ''}`));
      });
      const fields = record.total_fields ?? record.values.length;
      if (fields > record.values.length) values.append(textNode('li', `仅展示前 ${record.values.length} 个磁盘字段，原记录 ${fields} 个字段。`));
      row.append(values); el('records').append(row);
    }
    previewReport = result.export; el('preview-export').disabled = false;
    const changed = previewBudgetsChanged(result.export.budgets);
    el('preview-next').disabled = !result.more || changed || openingBudgetChanged;
    el('preview-status').textContent = `根页 ${previewRoot} · 本批 ${result.records.length} 条 · 累计 ${result.progress.records_read} 条 · ${result.more ? '游标已暂停，可继续读取' : reasons[result.result.reason] ?? '读取未完成'} ${result.error?.message ?? ''}`;
    if (result.export.budgets.limit !== result.export.budgets.requested_limit) el('preview-status').textContent += ` · 实际累计上限 ${result.export.budgets.limit}，受打开时的最多记录限制`;
    if (result.display?.paused_at_display_budget) el('preview-status').textContent += ' · 本批展示字符预算已用尽，继续读取下一批';
    if (result.display?.paused_at_payload_threshold) el('preview-status').textContent += ' · 大值已达到本批 4 MiB 门槛，继续读取下一批';
    if (!result.records.length && el('records').childElementCount) el('preview-status').textContent += ' · 没有新增记录，保留上批展示';
    // 晚到结果仍属于原预算，不覆盖读取期间输入变更带来的重新开始要求。
    if (openingBudgetChanged) el('preview-status').textContent += ' · 打开预算已修改，请先“重新读取对象”。';
    else if (changed) el('preview-status').textContent += ' · 累计预算已修改，请重新预览；导出仍对应实际执行预算。';
  } catch (error) { if (ticket === generation && request === previewRequest) el('preview-status').textContent = error.message; }
  finally { if (ticket === generation && request === previewRequest) { el('preview-start').disabled = !canPreview(); el('objects').disabled = false; el('cancel').disabled = true; } }
}
for (const id of ['preview-limit', 'max-payload', 'timeout']) el(id).addEventListener('input', () => {
  if (!previewReport) return;
  el('preview-next').disabled = true;
  el('preview-status').textContent = '累计预算已修改，请点击“预览所选对象”重新预览。当前导出仍对应上次实际执行预算。';
});
for (const id of ['max-rows', 'max-pages']) el(id).addEventListener('input', () => {
  if (!data) return;
  openingBudgetChanged = true; el('preview-start').disabled = true; el('preview-next').disabled = true;
  el('preview-status').textContent = '打开预算已修改，请先“重新读取对象”，再选择对象预览。';
});
el('preview-start').onclick = () => showRecords(true);
el('preview-next').onclick = () => showRecords(false);
el('go').onclick = () => showPage(Number(el('page-number').value));
el('page-number').onkeydown = event => { if (event.key === 'Enter') showPage(Number(event.target.value)); };
el('previous').onclick = () => showPage(selected - 1); el('next').onclick = () => showPage(selected + 1);
el('cells').onchange = event => { rawOffset = Number(event.target.value); renderRaw(); };
el('raw-previous').onclick = () => { rawOffset = Math.max(0, rawOffset - 256); renderRaw(); };
el('raw-next').onclick = () => { rawOffset += 256; renderRaw(); };
