// 每个 Worker 拥有一个静态快照；主线程切换文件时关闭旧快照并释放资源。
let database = null, operation = null;
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
      const dbSource = new BlobSource(message.file), walSource = message.wal ? new BlobSource(message.wal) : null;
      let lastProgress = 0;
      const onProgress = progress => {
        const now = performance.now();
        if (now - lastProgress >= 80) {
          self.postMessage({id: message.id, progress}); lastProgress = now;
        }
      };
      const timer = setTimeout(() => controller.abort(new Error('达到检查时间预算')), message.timeout * 1000);
      try {
        database = await openDatabase(dbSource, {...message.options, wal: walSource,
          signal: controller.signal, onProgress});
        const result = await database.inspectDatabase({signal: controller.signal, onProgress,
          max_total_payload_bytes: message.options.max_total_payload_bytes});
        result.io = statistics(dbSource, walSource);
        result.wal = database.source instanceof WalSource ? database.source.inspection : null;
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
  } catch (error) { self.postMessage({id: message.id, error: {kind: error.kind || 'host_failure', message: error.message}}); }
};
