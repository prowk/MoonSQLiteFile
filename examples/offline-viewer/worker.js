// 每个 Worker 拥有一个静态快照；主线程切换文件时关闭旧快照并释放资源。
let database = null, operation = null, preview = null, previewController = null;
let dbSource, walSource;
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
      const timer = setTimeout(() => controller.abort(new SqliteError('limit_exceeded', '达到检查时间预算')), message.timeout * 1000);
      try {
        database = await openDatabase(dbSource, {...message.options, wal: walSource,
          signal: controller.signal, onProgress});
        let result;
        if (message.check) {
          result = await database.inspectDatabase({signal: controller.signal, onProgress,
            max_total_payload_bytes: message.options.max_total_payload_bytes});
          result.export = reportEnvelope(result, {scope: 'database_structure', budgets});
        } else {
          const schema = await database.schema({signal: controller.signal, onProgress, limit: message.schemaLimit,
            max_total_payload_bytes: message.options.max_total_payload_bytes});
          result = {header: database.header, schema};
          result.export = reportEnvelope(schema, {scope: 'schema', budgets: {...budgets, limit: message.schemaLimit}});
        }
        result.io = statistics(dbSource, walSource);
        result.wal = database.source instanceof WalSource ? database.source.inspection : null;
        self.postMessage({id: message.id, result});
      } finally { clearTimeout(timer); if (operation === controller) operation = null; }
    } else if (message.op === 'preview-close') {
      const previous = preview; preview = null; previewController = null;
      await previous?.return();
      self.postMessage({id: message.id, result: {stopped: true}});
    } else if (message.op === 'preview') {
      if (!database) throw new ParameterError('尚未打开数据库');
      const controller = message.reset || !preview ? new AbortController() : previewController;
      operation = controller;
      const timer = setTimeout(() => controller.abort(new SqliteError('limit_exceeded', '达到预览时间预算')), message.timeout * 1000);
      try {
        if (message.reset || !preview) {
          await preview?.return();
          previewController = controller;
          preview = database.scan(message.root, {limit: message.limit, max_total_payload_bytes: message.payload, signal: controller.signal});
        }
        // 每批只拉取请求条数；保留原始记录和游标，不为继续读取重新扫描前缀。
        const records = [];
        let error;
        try {
          for (let index = 0; index < message.batch; index++) {
            checkAbort(controller.signal);
            const event = await preview.next();
            if (event.done) break;
            records.push(event.value);
          }
        } catch (failure) { error = errorInfo(failure); await preview.return(); }
        const result = {records, progress: preview.progress, result: preview.result, more: !preview.result, error};
        result.export = reportEnvelope(preview.result ?? {...preview.progress, status: 'incomplete', reason: 'preview_paused'},
          {scope: 'records', budgets: {root: message.root, limit: message.limit, max_total_payload_bytes: message.payload}});
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
