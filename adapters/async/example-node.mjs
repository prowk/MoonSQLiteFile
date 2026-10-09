import {openDatabase, reportEnvelope} from '@prowk/moonsqlitefile-async';
import {openFileSource} from '@prowk/moonsqlitefile-async/node';

/** 读取静态 db/WAL 副本；源接管、背压与提前退出均在实际安装包上运行。 */
export async function previewFiles(path, walPath, signal) {
  const source = await openFileSource(path);
  let wal;
  try { if (walPath) wal = await openFileSource(walPath); }
  catch (error) { await source.close(); throw error; }
  const db = await openDatabase(source, {wal, signal});
  try {
    const schema = await db.schema({limit: 100, signal});
    const object = schema.entries.find(entry => entry.root_page > 1);
    const rows = [];
    if (object) for await (const row of db.scan(object.root_page, {limit: 3, signal})) rows.push(row);
    return {schema: reportEnvelope(schema, {scope: 'schema', budgets: {limit: 100}}), rows};
  } finally { await db.close(); }
}
