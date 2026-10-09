import {BlobSource, openDatabase, reportEnvelope} from './index.mjs';

/** 浏览器只读取调用者选择的本地文件；不执行上传或网络读取。 */
export async function previewBlobs(file, walFile, signal) {
  const db = await openDatabase(new BlobSource(file), {wal: walFile ? new BlobSource(walFile) : undefined, signal});
  try {
    const schema = await db.schema({limit: 100, signal});
    const object = schema.entries.find(entry => entry.root_page > 1);
    const rows = [];
    if (object) for await (const row of db.scan(object.root_page, {limit: 3, signal})) rows.push(row);
    return {schema: reportEnvelope(schema, {scope: 'schema', budgets: {limit: 100}}), rows};
  } finally { await db.close(); }
}
