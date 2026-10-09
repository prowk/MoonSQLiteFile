import {openDatabase, reportEnvelope, errorInfo} from '@prowk/moonsqlitefile-async';
import {openFileSource} from '@prowk/moonsqlitefile-async/node';
import {pathToFileURL} from 'node:url';

/** 独立项目从安装包读取静态 db/WAL，不导入仓库源码或 core。 */
export async function inspectCopies(path, walPath, signal) {
  const source = await openFileSource(path);
  let wal;
  try { if (walPath) wal = await openFileSource(walPath); }
  catch (error) { await source.close(); throw error; }
  const db = await openDatabase(source, {wal, signal});
  try {
    const schema = await db.schema({signal, limit: 100});
    const object = schema.entries.find(entry => entry.root_page > 1);
    const records = [];
    let scan;
    if (object) {
      scan = db.scan(object.root_page, {signal, limit: 3});
      try { for await (const record of scan) records.push(record); }
      catch (error) { if (errorInfo(error).category !== 'cancelled') throw error; }
    }
    return {schema: reportEnvelope(schema, {scope: 'schema', budgets: {limit: 100}}), records,
      preview: scan?.result ? reportEnvelope(scan.result, {scope: 'records', budgets: {limit: 3, root: object.root_page}}) : null};
  } finally { await db.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const controller = new AbortController(), cancel = () => controller.abort();
  process.on('SIGINT', cancel);
  try { console.log(JSON.stringify(await inspectCopies(process.argv[2], process.argv[3], controller.signal))); }
  catch (error) { console.error(JSON.stringify(errorInfo(error))); process.exitCode = 1; }
  finally { process.removeListener('SIGINT', cancel); }
}
