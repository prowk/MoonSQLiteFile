import compiledCore from './core.mjs';

/** 参数错误保留 TypeError 兼容，kind 提供稳定判别。 */
export class ParameterError extends TypeError {
  constructor(message) { super(message); this.name = 'ParameterError'; this.kind = 'invalid_argument'; }
}
/** 将异常转换为稳定类别；不读取消息前缀，未知回调异常归为宿主失败。 */
export function errorInfo(error) {
  const kind = error?.kind ?? 'host_failure';
  const category = kind === 'invalid_argument' ? 'argument' : kind === 'invalid' ? 'corruption'
    : kind === 'limit_exceeded' ? 'budget' : kind === 'cancelled' ? 'cancelled'
    : kind === 'unsupported' ? 'unsupported' : 'source';
  return {category, kind, message: error?.message ?? String(error)};
}
const reportFailures = new WeakMap();
/** 包装原始报告而不改变已发布 JSON；保留完成度、预算、范围及程序化诊断。 */
export function reportEnvelope(result, {scope, budgets = {}}) {
  const report = result.inspection ?? result;
  const diagnostics = [...(reportFailures.get(result) ?? [])];
  for (const [index, issue] of (report.issues ?? []).entries()) {
    const location = result.locations?.[index] ?? {page_number: issue.page_number ?? null};
    if (!diagnostics.some(item => item.issue_index === index || (issue.code === 'scan_error' && issue.error_kind === 'unsupported' && location?.phase === 'read_page' && item.category === 'source' && item.location?.page_number === location?.page_number))) {
      diagnostics.push({...errorInfo({kind: issue.error_kind ?? (issue.code === 'unsupported_feature' ? 'unsupported' : 'invalid'), message: issue.message ?? issue.code}), code: issue.code, location});
    }
  }
  if (report.error) diagnostics.push({...errorInfo(report.error), location: report.location ?? null});
  else if (report.diagnostic) diagnostics.push({...errorInfo({kind: report.diagnostic.error_kind, message: report.diagnostic.message}),
    code: report.diagnostic.code, location: {phase: 'page_layout', page_number: report.diagnostic.page_number, byte_offset: report.diagnostic.byte_offset, cell_index: report.diagnostic.cell_index}});
  if (report.completion === 'record_limit') diagnostics.push(errorInfo(new SqliteError('limit_exceeded', '达到记录数量预算')));
  if (result.reason === 'cancelled' && !diagnostics.some(item => item.category === 'cancelled')) diagnostics.push(errorInfo(new CancelledError()));
  return {format: 'moonsqlitefile-report', format_version: 1, tool_version: '0.8.0-dev', scope,
    budgets: JSON.parse(JSON.stringify(budgets, (_, value) => typeof value === 'bigint' ? String(value) : value)),
    status: report.status, partial: report.status !== 'complete', diagnostics, result: {...result}};
}

// 所有异步 I/O 与生命周期留在适配层，格式校验由 MoonBit 核心完成。
/** 宿主错误；kind 为 range_out_of_bounds、short_read 或 host_failure，不代表 SQLite 损坏。 */
export class SourceError extends Error {
  constructor(kind, message) { super(message); this.name = 'SourceError'; this.kind = kind; }
}
/** 可辨认的取消错误；kind 固定为 cancelled，不应作为格式损坏。 */
export class CancelledError extends Error {
  constructor(message = '操作已取消') { super(message); this.name = 'CancelledError'; this.kind = 'cancelled'; }
}
/** 核心格式/预算错误；kind 保留 Invalid、Unsupported 或 LimitExceeded 对应类别。 */
export class SqliteError extends Error {
  constructor(kind, message) { super(message); this.name = 'SqliteError'; this.kind = kind; }
}
/** signal 已取消时抛 CancelledError；没有 signal 时不做操作。 */
export function checkAbort(signal) {
  validateSignal(signal);
  if (signal?.aborted) throw abortError(signal);
}
function validateSignal(signal) {
  if (signal !== undefined && (!signal || typeof signal.aborted !== 'boolean' || typeof signal.addEventListener !== 'function' || typeof signal.removeEventListener !== 'function')) throw new ParameterError('signal 必须为 AbortSignal');
  if (signal !== undefined) {
    try { Object.getOwnPropertyDescriptor(AbortSignal.prototype, 'aborted').get.call(signal); }
    catch { throw new ParameterError('signal 必须为 AbortSignal'); }
  }
}
function optionsObject(options) {
  if (!options || typeof options !== 'object' || Array.isArray(options)) throw new ParameterError('options 必须为配置对象');
  validateSignal(options.signal);
}
// 回调是宿主边界；即使异常伪造核心 kind，也不能把业务错误当成损坏。
function callbackError(error) {
  const failure = new SourceError('host_failure', error?.message ?? String(error));
  failure.cause = error;
  return failure;
}
function notify(callback, progress) {
  try { callback?.(progress); } catch (error) { throw callbackError(error); }
}
function abortError(signal) {
  return signal.reason instanceof SqliteError && signal.reason.kind === 'limit_exceeded'
    ? signal.reason : new CancelledError(signal.reason?.message || '操作已取消');
}
/** 让等待操作响应 signal；不会强制终止底层系统 I/O，晚到结果和异常仍被处理。 */
export function withAbort(operation, signal) {
  const promise = Promise.resolve(operation);
  try { validateSignal(signal); } catch (error) { promise.catch(() => {}); return Promise.reject(error); }
  if (!signal) return promise;
  if (signal.aborted) { promise.catch(() => {}); return Promise.reject(abortError(signal)); }
  return new Promise((resolve, reject) => {
    const abort = () => { cleanup(); reject(abortError(signal)); };
    const cleanup = () => signal.removeEventListener('abort', abort);
    signal.addEventListener('abort', abort, {once: true});
    promise.then(value => { cleanup(); resolve(value); }, error => { cleanup(); reject(error); });
  });
}
function range(size, offset, count) {
  if (typeof size !== 'bigint' || size < 0n || size > 9223372036854775807n ||
      typeof offset !== 'bigint' || !Number.isInteger(count) || count < 0 || count > 2147483647 ||
      offset < 0n || offset > size || BigInt(count) > size - offset) {
    throw new SourceError('range_out_of_bounds', '范围读取越界或整数类型不符合约定');
  }
}
// 在 JSON 桥接前检查整数，避免 MoonBit 的 Int 解码静默截断小数。
function integer(value, name, minimum = 1, maximum = 2147483647) {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < minimum || value > maximum) {
    throw new ParameterError(`${name} 必须为 ${minimum}–${maximum} 范围内的整数 number`);
  }
  return value;
}
function integerOptions(options, names) {
  for (const name of names) if (options[name] !== undefined) integer(options[name], name);
}
function payloadBudget(value = 67108864n) {
  if (!((typeof value === 'bigint' && value >= 0n && value <= 18446744073709551615n) ||
      (typeof value === 'string' && /^[0-9]+$/.test(value) && BigInt(value) <= 18446744073709551615n))) {
    throw new ParameterError('max_total_payload_bytes 必须为 UInt64 BigInt 或十进制文本');
  }
  return String(value);
}
/** 检查非负有符号 64 位 BigInt 范围及 Int32 长度，精确读取 Uint8Array；宿主失败与短读分别分类。 */
export async function readExact(source, offset, count, signal) {
  checkAbort(signal);
  range(source.size, offset, count);
  try {
    const bytes = await withAbort(Promise.resolve().then(() => {
      checkAbort(signal);
      return source.read(offset, count, {signal});
    }), signal);
    checkAbort(signal);
    if (!(bytes instanceof Uint8Array) || bytes.length !== count) {
      throw new SourceError('short_read', `请求 ${count} 字节，实际返回 ${bytes?.length ?? '无效数据'}`);
    }
    return bytes;
  } catch (error) {
    if (error instanceof CancelledError || error instanceof SourceError || error === signal?.reason && error instanceof SqliteError && error.kind === 'limit_exceeded') throw error;
    throw new SourceError('host_failure', error?.message || String(error));
  }
}
/** 不可变 Blob 的分块源；每次只 slice 当前范围，close 释放引用，所有偏移为 BigInt。 */
export class BlobSource {
  constructor(blob) {
    if (!blob || !Number.isSafeInteger(blob.size) || typeof blob.slice !== 'function') throw new ParameterError('需要有效 Blob');
    this.blob = blob; this.size = BigInt(blob.size); this.closed = false;
    this.statistics = {reads: 0, bytes: 0, maxRead: 0};
  }
  async read(offset, count, options = {}) {
    optionsObject(options); const {signal} = options;
    checkAbort(signal); range(this.size, offset, count);
    if (this.closed) throw new SourceError('host_failure', 'Blob 源已关闭');
    const bytes = new Uint8Array(await withAbort(this.blob.slice(Number(offset), Number(offset) + count).arrayBuffer(), signal));
    checkAbort(signal);
    if (this.closed) throw new SourceError('host_failure', 'Blob 源在读取期间关闭');
    this.statistics.reads++; this.statistics.bytes += bytes.length;
    this.statistics.maxRead = Math.max(this.statistics.maxRead, count);
    return bytes;
  }
  async close() { this.closed = true; this.blob = null; }
}
/** 有界 FIFO 块缓存；返回副本，失败/取消不缓存，closeSources 控制是否关闭被包装源。 */
export class CachedSource {
  constructor(source, options = {}) {
    optionsObject(options);
    const {blockSize = 4096, cachePages = 256, closeSource = true} = options;
    if (typeof closeSource !== 'boolean') throw new ParameterError('closeSource 必须为 boolean');
    if (!source || typeof source.read !== 'function') throw new ParameterError('source 必须实现异步范围读取');
    if (!Number.isInteger(blockSize) || blockSize < 1 || blockSize > 65536 ||
        !Number.isInteger(cachePages) || cachePages < 1 || cachePages > 1048576) throw new ParameterError('缓存预算无效');
    range(source.size, 0n, 0);
    this.source = source; this.size = source.size; this.blockSize = blockSize; this.capacity = cachePages;
    this.blocks = new Map(); this.closed = false; this.closeSource = closeSource;
    this.statistics = {hits: 0, misses: 0, bytes: 0, residentPages: 0};
  }
  async read(offset, count, options = {}) {
    optionsObject(options); const {signal} = options;
    checkAbort(signal); range(this.size, offset, count);
    if (this.closed) throw new SourceError('host_failure', '缓存源已关闭');
    const output = new Uint8Array(count);
    let copied = 0;
    while (copied < count) {
      checkAbort(signal);
      const position = offset + BigInt(copied), key = position / BigInt(this.blockSize);
      const start = key * BigInt(this.blockSize);
      let bytes = this.blocks.get(key);
      if (bytes) this.statistics.hits++;
      else {
        const length = Number(this.size - start < BigInt(this.blockSize) ? this.size - start : BigInt(this.blockSize));
        bytes = (await readExact(this.source, start, length, signal)).slice();
        checkAbort(signal);
        if (this.closed) throw new SourceError('host_failure', '缓存源在读取期间关闭');
        this.statistics.misses++; this.statistics.bytes += length;
        if (!this.blocks.has(key) && this.blocks.size >= this.capacity) this.blocks.delete(this.blocks.keys().next().value);
        this.blocks.set(key, bytes); this.statistics.residentPages = this.blocks.size;
      }
      const inBlock = Number(position - start), length = Math.min(count - copied, bytes.length - inBlock);
      output.set(bytes.subarray(inBlock, inBlock + length), copied); copied += length;
    }
    return output;
  }
  close() {
    if (!this.closePromise) {
      this.closed = true; this.blocks.clear(); this.statistics.residentPages = 0;
      this.closePromise = Promise.resolve().then(() => this.closeSource ? this.source.close?.() : undefined);
    }
    return this.closePromise;
  }
}
function bridge(core, request, bytes) {
  const result = core(request, bytes);
  if (!result.ok) throw new SqliteError(result.error.kind, result.error.message);
  return result.result;
}
function failure(error) {
  const kind = error.kind || 'host_failure';
  return {status: error instanceof SqliteError && kind === 'invalid' ? 'failed' : 'incomplete',
    reason: kind, error: {kind, message: error.message}};
}
/** 由核心验证索引指定实际来源的静态 db/WAL 覆盖源；应通过 openDatabase 创建，不能自行重写覆盖规则。 */
export class WalSource {
  constructor(base, wal, core, index, report) {
    this.base = base; this.wal = wal; this.core = core; this.index = index.id;
    this.size = BigInt(index.size); this.pageSize = index.page_size; this.pageCount = index.page_count;
    this.inspection = report; this.closed = false;
  }
  async read(offset, count, options = {}) {
    optionsObject(options); const {signal} = options;
    checkAbort(signal); range(this.size, offset, count);
    if (this.closed) throw new SourceError('host_failure', 'WAL 快照已关闭');
    const output = new Uint8Array(count);
    let copied = 0;
    while (copied < count) {
      checkAbort(signal);
      const position = offset + BigInt(copied), page = Number(position / BigInt(this.pageSize)) + 1;
      const inPage = Number(position % BigInt(this.pageSize)), length = Math.min(count - copied, this.pageSize - inPage);
      const origin = bridge(this.core, {op: 'index-page', id: this.index, page});
      output.set(await readExact(origin.source === 'wal' ? this.wal : this.base, BigInt(origin.offset) + BigInt(inPage), length, signal), copied);
      copied += length;
    }
    return output;
  }
  close() {
    if (!this.closePromise) {
      this.closed = true;
      this.closePromise = Promise.resolve().then(async () => {
        const closed = await Promise.allSettled([
          Promise.resolve().then(() => bridge(this.core, {op: 'index-close', id: this.index})),
          Promise.resolve().then(() => this.base.close?.()),
          Promise.resolve().then(() => this.wal.close?.()),
        ]);
        const errors = closed.filter(result => result.status === 'rejected').map(result => result.reason);
        if (errors.length) throw new AggregateError(errors, '一个或多个 WAL 配对宿主源关闭失败');
      });
    }
    return this.closePromise;
  }
}
async function openWal(base, wal, options, core) {
  const {signal, onProgress} = options;
  let id, index;
  try {
    id = bridge(core, {op: 'wal-new', size: String(wal.size), max_frames: options.max_frames ?? 100000}).id;
    let report, ticks = 0;
    while (true) {
      checkAbort(signal);
      // 内存源和缓存命中也让出执行权，使宿主定时取消能在校验期间生效。
      if (++ticks % 64 === 0) await withAbort(new Promise(done => setTimeout(done, 0)), signal);
      const event = bridge(core, {op: 'wal-next', id});
      if (event.kind === 'done') { report = event.report; break; }
      notify(onProgress, {phase: 'wal', frames_read: event.frames_read, offset: event.offset});
      const bytes = await readExact(wal, BigInt(event.offset), event.count, signal);
      bridge(core, {op: 'wal-supply', id, offset: event.offset}, bytes);
    }
    checkAbort(signal);
    const header = base.size === 0n ? new Uint8Array(0) : await readExact(base, 0n, 100, signal);
    index = bridge(core, {op: 'wal-index', id, base_size: String(base.size), wal_size: String(wal.size),
      tail_policy: options.tailPolicy ?? 'strict', max_overlay_pages: options.max_overlay_pages ?? 100000}, header);
    return new WalSource(base, wal, core, index, report);
  } catch (error) {
    if (index) bridge(core, {op: 'index-close', id: index.id});
    throw error;
  } finally { if (id) bridge(core, {op: 'wal-close', id}); }
}
/** 逐条异步迭代器；消费者等待时不预读，不允许并发 next，return/break 释放游标并保存部分结果。 */
export class Scan {
  constructor(database, root, options = {}) {
    database.assertOpen();
    optionsObject(options);
    integer(root, 'root');
    if (root > database.header.page_count) throw new ParameterError('根页号越界');
    const limit = integer(options.limit === undefined ? database.options.max_rows ?? 100000 : options.limit, 'limit', 0);
    if (limit > (database.options.max_rows ?? 100000)) throw new ParameterError('limit 不得超过打开时的 max_rows');
    const payload = payloadBudget(options.max_total_payload_bytes);
    this.database = database; this.options = options; this.controller = new AbortController();
    this.signal = AbortSignal.any([this.controller.signal, database.controller.signal, ...(options.signal ? [options.signal] : [])]);
    checkAbort(this.signal);
    this.id = database.call({op: 'scan-new', root, limit,
      schema: options.schema ? 'true' : 'false', max_total_payload_bytes: payload}).id;
    this.progress = {records_read: 0, pages_read: 0, payload_bytes: '0'}; this.result = null; this.pending = null; this.ticks = 0;
    database.scans.add(this);
  }
  [Symbol.asyncIterator]() { return this; }
  async next() {
    if (this.pending) throw new ParameterError('同一扫描不可同时调用 next');
    if (this.result) return {done: true, value: this.result};
    this.pending = this.advance();
    try { return await this.pending; } finally { this.pending = null; }
  }
  async advance() {
    try {
      while (true) {
        checkAbort(this.signal);
        if (++this.ticks % 64 === 0) await withAbort(new Promise(done => setTimeout(done, 0)), this.signal);
        const event = this.database.call({op: 'scan-next', id: this.id}, undefined, false);
        if (event.kind === 'page') {
          const bytes = await this.database.readPage(event.page, this.signal);
          checkAbort(this.signal);
          this.database.call({op: 'scan-supply', id: this.id, page: event.page}, bytes, false);
        } else if (event.kind === 'record') {
          this.progress = event.progress; notify(this.options.onProgress, {phase: 'scan', ...this.progress});
          return {done: false, value: event.record};
        } else {
          this.result = {status: event.summary.completion === 'complete' ? 'complete' : 'incomplete',
            reason: event.summary.completion, ...event.summary};
          this.release(); return {done: true, value: this.result};
        }
      }
    } catch (error) {
      let location;
      try { const state = this.database.call({op: 'scan-progress', id: this.id}, undefined, false); this.progress = state.progress; location = state.location; } catch {}
      this.result = {...failure(error), ...this.progress, location}; this.release(); throw error;
    }
  }
  release() {
    if (!this.id) return;
    try { this.database.call({op: 'scan-close', id: this.id}, undefined, false); } finally {
      this.id = null; this.database.scans.delete(this);
    }
  }
  async return() {
    this.controller.abort();
    if (this.pending) await this.pending.catch(() => {});
    if (!this.result) {
      const summary = this.database.call({op: 'scan-close', id: this.id}, undefined, false);
      this.id = null; this.database.scans.delete(this);
      this.result = {status: 'incomplete', reason: 'visitor_stopped', ...summary};
    } else this.release();
    return {done: true, value: this.result};
  }
}
/** 已打开静态视图；扫描和检查返回完整度/部分证据，调用者须在 finally 中 await close 释放接管源。 */
export class Database {
  constructor(core, handle, source, options) {
    this.core = core; this.id = handle.id; this.header = handle.header; this.source = source; this.options = options;
    this.closed = false; this.controller = new AbortController(); this.scans = new Set();
  }
  assertOpen() { if (this.closed || this.closePromise) throw new SourceError('host_failure', '数据库已关闭或正在关闭'); }
  call(request, bytes, context = true) {
    // 关闭中的内部游标仍须提交取消和释放，新的公开操作由 assertOpen 拒绝。
    if (this.closed) throw new SourceError('host_failure', '数据库已关闭');
    return bridge(this.core, {...request, ...(context ? {id: this.id} : {})}, bytes);
  }
  async readPage(page, signal) {
    this.assertOpen();
    validateSignal(signal);
    integer(page, 'page');
    if (page > this.header.page_count) throw new ParameterError('页号越界');
    signal = AbortSignal.any([this.controller.signal, ...(signal === undefined ? [] : [signal])]);
    return readExact(this.source, BigInt(page - 1) * BigInt(this.header.page_size), this.header.page_size, signal);
  }
  async inspectPage(page, options = {}) {
    try { optionsObject(options); return this.call({op: 'page-inspect', page}, await this.readPage(page, options.signal)); }
    catch (error) { return {...failure(error), status: 'incomplete', page: null, statistics: null,
      diagnostic: {code: 'page_read', page_number: page, byte_offset: null, cell_index: null,
        error_kind: error instanceof SqliteError ? error.kind : 'unsupported', message: error.message}}; }
  }
  scan(root, options) { return new Scan(this, root, options); }
  async scanBtree(root, visitor, options = {}) {
    const scan = this.scan(root, options);
    try {
      for await (const record of scan) {
        const visited = Promise.resolve().then(() => visitor(record, scan.signal)).catch(error => { throw callbackError(error); });
        if (await withAbort(visited, scan.signal) === false) break;
      }
      return scan.result;
    } catch (error) {
      if (!scan.result?.error) scan.result = {...failure(error), reason: error.kind ?? 'visitor_failure', ...scan.progress};
      return scan.result;
    }
    finally { if (scan.id) await scan.return(); }
  }
  async schema(options = {}) {
    optionsObject(options);
    const entries = [];
    const report = await this.scanBtree(1, entry => { entries.push(entry); return true; }, {...options, schema: true});
    return {entries, ...report};
  }
  async inspectDatabase(options = {}) {
    this.assertOpen();
    optionsObject(options);
    integerOptions(options, ['max_issues']);
    const payload = payloadBudget(options.max_total_payload_bytes);
    const controller = new AbortController();
    const signal = AbortSignal.any([controller.signal, this.controller.signal, ...(options.signal ? [options.signal] : [])]);
    const id = this.call({op: 'inspection-new', max_issues: options.max_issues ?? 100,
      max_total_payload_bytes: payload}).id;
    let result, ticks = 0, lastLocation = null;
    const failures = [];
    const job = {return: async () => { controller.abort(); await pending; }};
    let resolve;
    const pending = new Promise(done => { resolve = done; });
    this.scans.add(job);
    try {
      while (true) {
        checkAbort(signal);
        const event = this.call({op: 'inspection-next', id}, undefined, false);
        if (event.kind === 'done') { result = event.data; break; }
        if (event.kind === 'page') {
          lastLocation = {phase: 'read_page', page_number: event.page, byte_offset: null, cell_index: null};
          try {
            const bytes = await this.readPage(event.page, signal);
            checkAbort(signal);
            this.call({op: 'inspection-supply', id, page: event.page}, bytes, false);
          } catch (error) {
            if (error instanceof CancelledError || error === signal.reason && error instanceof SqliteError && error.kind === 'limit_exceeded') throw error;
            failures.push({...errorInfo(error), location: {phase: 'read_page', page_number: event.page, byte_offset: null, cell_index: null}});
            this.call({op: 'inspection-reject', id, message: `source/${error.kind || 'host_failure'}: ${error.message}`}, undefined, false);
          }
        } else {
          lastLocation = event.location;
          notify(options.onProgress, {phase: 'inspection', ...event.progress, location: event.location});
        }
        // 缓存命中时也定期让出事件循环，使取消不依赖下一次磁盘读取。
        if (++ticks % 64 === 0) await withAbort(new Promise(done => setTimeout(done, 0)), signal);
      }
      reportFailures.set(result, failures);
      return result;
    } catch (error) {
      result = this.call({op: 'inspection-close', id, message: `${error.kind || 'host_failure'}: ${error.message}`}, undefined, false);
      result.reason = error.kind || 'host_failure';
      // 截断时 stop 未追加诊断，不能把最后一项旧损坏误当成本次停止原因。
      const last = result.inspection.issues.length - 1;
      const appended = !result.inspection.diagnostics_truncated && result.inspection.issues[last]?.error_kind === 'unsupported';
      failures.push({...errorInfo(error), location: appended ? result.locations[last] : lastLocation,
        ...(appended ? {issue_index: last} : {})});
      reportFailures.set(result, failures);
      return result;
    } finally {
      if (!result?.reason) this.call({op: 'inspection-close', id}, undefined, false);
      this.scans.delete(job); resolve();
    }
  }
  close() {
    if (!this.closePromise) {
      // 同步登记共享 Promise；所有调用者都等待同一次关闭，包括同一次失败。
      this.closePromise = Promise.resolve().then(async () => {
        await Promise.allSettled([...this.scans].map(scan => scan.return()));
        const errors = [];
        try { bridge(this.core, {op: 'close', id: this.id}); } catch (error) { errors.push(error); }
        this.closed = true;
        try { await this.source.close?.(); } catch (error) { errors.push(error); }
        if (errors.length === 1) throw errors[0];
        if (errors.length > 1) throw new AggregateError(errors, '数据库及宿主源关闭失败');
      });
      this.controller.abort();
    }
    return this.closePromise;
  }
}
/** 从异步静态源打开库及可选 WAL；默认接管源，失败时清理。closeSources:false 保留原始源，初始化失败没有可用 Database。 */
export async function openDatabase(source, options = {}) {
  const core = options?.core ?? compiledCore;
  const closeSources = options?.closeSources !== false;
  let cached, wal;
  try {
    optionsObject(options);
    if (options.closeSources !== undefined && typeof options.closeSources !== 'boolean') throw new ParameterError('closeSources 必须为 boolean');
    integerOptions(options, ['max_rows', 'max_pages', 'max_payload_bytes', 'max_depth',
      'max_report_pages', 'max_frames', 'max_overlay_pages']);
    if (options.tailPolicy !== undefined && !['strict', 'valid_prefix'].includes(options.tailPolicy)) throw new ParameterError('tailPolicy 必须为 strict 或 valid_prefix');
    cached = new CachedSource(source, {blockSize: options.blockSize, cachePages: options.cachePages, closeSource: options.closeSources !== false});
    if (options.wal) {
      wal = new CachedSource(options.wal, {blockSize: options.blockSize, cachePages: options.cachePages, closeSource: options.closeSources !== false});
      cached = await openWal(cached, wal, options, core);
    }
    const header = await readExact(cached, 0n, 100, options.signal);
    checkAbort(options.signal);
    const limits = Object.fromEntries(['max_rows', 'max_pages', 'max_payload_bytes', 'max_depth', 'max_report_pages']
      .filter(key => options[key] !== undefined).map(key => [key, options[key]]));
    const request = {...limits, op: cached instanceof WalSource ? 'index-open' : 'open',
      id: cached instanceof WalSource ? cached.index : 0, size: String(cached.size)};
    const handle = bridge(core, request, header);
    return new Database(core, handle, cached, options);
  } catch (error) {
    // 构造缓存之前的参数/源错误也属于打开失败，须释放已接管的原始源。
    await Promise.allSettled([
      Promise.resolve().then(() => cached ? cached.close() : closeSources ? source?.close?.() : undefined),
      Promise.resolve().then(() => wal ? wal.close() : closeSources ? options?.wal?.close?.() : undefined),
    ]);
    throw error;
  }
}
