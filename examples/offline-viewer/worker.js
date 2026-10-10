// 每个 Worker 拥有一个静态快照；主线程切换文件时关闭旧快照并释放资源。
let database = null, operation = null, preview = null, previewController = null, previewBudgets = null, databaseBudgets = null;
let dbSource, walSource;
const DISPLAY_CHARACTERS = 262144, DISPLAY_FIELDS = 128, BATCH_PAYLOAD = 4194304n;
function displayRecord(record, valueLimit, budget) {
  const values = [];
  for (const value of record.values.slice(0, DISPLAY_FIELDS)) {
    const text = String(value.value), remaining = DISPLAY_CHARACTERS - budget.used;
    const canTruncate = value.type === 'text' || value.type === 'blob';
    if (remaining <= 0 || !canTruncate && remaining < text.length) { budget.exhausted = true; break; }
    const count = canTruncate ? Math.min(text.length, valueLimit, remaining) : text.length;
    // split/join 复制前缀，避免短子串继续持有完整大值的底层字符串。
    values.push({...value, value: count < text.length ? text.slice(0, count).split('').join('') : value.value,
      original_characters: text.length, truncated: count < text.length});
    budget.used += count;
  }
  if (budget.used === DISPLAY_CHARACTERS) budget.exhausted = true;
  return {...record, values, total_fields: record.values.length};
}
function statistics(dbSource, walSource) {
  return {db: dbSource.statistics, wal: walSource?.statistics ?? null,
    handles: compiledCore({op: 'stats'}).result};
}
self.onmessage = async ({data: message}) => {
  if (message.op === 'cancel') { operation?.abort(); return; }
  if (message.op === 'close') {
    operation?.abort();
    await database?.close(); database = null;
    self.postMessage({id: message.id, closed: true, handles: compiledCore({op: 'stats'}).result});
    return;
  }
  try {
    if (message.op === 'open') {
      const controller = new AbortController(); operation = controller;
      dbSource = new BlobSource(message.file); walSource = message.wal ? new BlobSource(message.wal) : null;
      let lastProgress = 0;
      const onProgress = progress => {
        const now = performance.now();
        if (now - lastProgress >= 80) {
          self.postMessage({id: message.id, progress}); lastProgress = now;
        }
      };
      const budgets = {blockSize: 4096, cachePages: 256, max_payload_bytes: 16777216, max_depth: 64,
        max_frames: 100000, max_overlay_pages: 100000, max_issues: 100, ...message.options, timeout_seconds: message.timeout};
      databaseBudgets = budgets;
      const timer = setTimeout(() => controller.abort(new SqliteError('limit_exceeded', '达到检查时间预算')), message.timeout * 1000);
      try {
        database = await openDatabase(dbSource, {...message.options, wal: walSource,
          signal: controller.signal, onProgress});
        const limit = Math.min(message.schemaLimit, database.options.max_rows ?? 100000);
        const schema = await database.schema({signal: controller.signal, onProgress, limit,
          max_total_payload_bytes: message.options.max_total_payload_bytes});
        let result;
        if (message.check) {
          result = await database.inspectDatabase({signal: controller.signal, onProgress,
            max_total_payload_bytes: message.options.max_total_payload_bytes});
          result.export = reportEnvelope(result, {scope: 'database_structure', budgets});
          result.schema = schema;
        } else {
          result = {header: database.header, schema};
          result.export = reportEnvelope(schema, {scope: 'schema', budgets: {...budgets, limit, requested_limit: message.schemaLimit}});
        }
        result.io = statistics(dbSource, walSource);
        result.wal = database.source instanceof WalSource ? database.source.inspection : null;
        self.postMessage({id: message.id, result});
      } finally { clearTimeout(timer); if (operation === controller) operation = null; }
    } else if (message.op === 'preview-close') {
      const previous = preview; preview = null; previewController = null; previewBudgets = null;
      await previous?.return();
      self.postMessage({id: message.id, result: {stopped: true}});
    } else if (message.op === 'preview') {
      if (!database) throw new ParameterError('尚未打开数据库');
      const valueLimit = message.valueLimit ?? 256;
      if (!Number.isInteger(message.batch) || message.batch < 1 || message.batch > 100 ||
        !Number.isInteger(valueLimit) || valueLimit < 16 || valueLimit > 4096) throw new ParameterError('预览批次或显示字符预算无效');
      if (!message.reset && preview && (message.limit !== previewBudgets.requested_limit ||
        message.root !== previewBudgets.root || String(message.payload) !== previewBudgets.max_total_payload_bytes || message.timeout !== previewBudgets.timeout_seconds)) {
        throw new ParameterError('预览预算已更改，请重新预览；继续读取只使用创建游标时的预算');
      }
      const controller = message.reset || !preview ? new AbortController() : previewController;
      operation = controller;
      const timer = setTimeout(() => controller.abort(new SqliteError('limit_exceeded', '达到预览时间预算')), message.timeout * 1000);
      try {
        if (message.reset || !preview) {
          await preview?.return();
          previewController = controller;
          previewBudgets = {...databaseBudgets, root: message.root, requested_limit: message.limit,
            limit: Math.min(message.limit, database.options.max_rows ?? 100000),
            max_total_payload_bytes: String(message.payload), timeout_seconds: message.timeout};
          preview = database.scan(message.root, {limit: previewBudgets.limit,
            max_total_payload_bytes: previewBudgets.max_total_payload_bytes, signal: controller.signal});
        }
        // 每批只拉取请求条数；保留原始记录和游标，不为继续读取重新扫描前缀。
        const records = [], display = {used: 0, exhausted: false};
        const initialPayload = BigInt(preview.progress.payload_bytes);
        let payloadPaused = false;
        let error;
        try {
          for (let index = 0; index < message.batch; index++) {
            checkAbort(controller.signal);
            const event = await preview.next();
            if (event.done) break;
            records.push(displayRecord(event.value, valueLimit, display));
            // 大值每批至多跨过一次 4 MiB 门槛；一条记录仍按打开时的单条预算完整解码。
            payloadPaused = BigInt(preview.progress.payload_bytes)-initialPayload >= BATCH_PAYLOAD;
            if (display.exhausted || payloadPaused) break;
          }
          // 已知累计记录预算用尽时只取停止摘要，不预读下一条记录。
          if (!preview.result && preview.progress.records_read >= previewBudgets.limit) await preview.next();
        } catch (failure) { error = errorInfo(failure); await preview.return(); }
        const result = {records, progress: preview.progress, result: preview.result, more: !preview.result, error,
          display: {characters: display.used, max_characters: DISPLAY_CHARACTERS, max_fields: DISPLAY_FIELDS,
            value_characters: valueLimit, paused_at_display_budget: display.exhausted,
            batch_payload_threshold: String(BATCH_PAYLOAD), paused_at_payload_threshold: payloadPaused}};
        result.export = reportEnvelope(preview.result ?? {...preview.progress, status: 'incomplete', reason: 'preview_paused'},
          {scope: 'records', budgets: {...previewBudgets, batch_records: message.batch,
            display_value_characters: valueLimit, display_max_fields: DISPLAY_FIELDS, display_max_characters: DISPLAY_CHARACTERS,
            display_batch_payload_threshold: String(BATCH_PAYLOAD)}});
        self.postMessage({id: message.id, result});
      } finally { clearTimeout(timer); if (operation === controller) operation = null; }
    } else if (message.op === 'page') {
      if (!database) throw new Error('尚未打开数据库');
      const bytes = await database.readPage(message.page);
      const owner = message.kind;
      const type = bytes[message.page === 1 ? 100 : 0];
      const btree = owner ? ['btree_root', 'btree_child'].includes(owner) : [2, 5, 10, 13].includes(type);
      const report = btree ? await database.inspectPage(message.page) : null;
      self.postMessage({id: message.id, result: {bytes, report}}, [bytes.buffer]);
    }
  } catch (error) { self.postMessage({id: message.id, error: errorInfo(error)}); }
};
