// 本地构建后的独立包消费示例；扫描结束后始终释放源和核心句柄。
import {openDatabase} from '../../_build/async-adapter/index.mjs';
import {openFileSource} from '../../_build/async-adapter/node.mjs';
const db = await openDatabase(await openFileSource(process.argv[2] || 'fixtures/core.sqlite'));
try {
  const schema = await db.schema();
  console.log(JSON.stringify(schema));
  if (schema.status !== 'complete') throw new Error(`schema: ${schema.reason}`);
  const entry = schema.entries.find(entry => entry.root_page > 0);
  if (entry) console.log(JSON.stringify(await db.scanBtree(entry.root_page, record => {
    console.log(JSON.stringify(record)); return true;
  }, {limit: 10})));
} finally { await db.close(); }
