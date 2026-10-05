# @prowk/moonsqlitefile-async

MoonSQLiteFile v0.7.0 的独立异步 JS 宿主适配器，本地开发版，尚未发布 npm。

从项目根目录执行 `moon build --target js --deny-warn` 和 `python tools/build_async.py`，得到包含编译核心的 `_build/async-adapter`；运行时没有第三方依赖。`index.mjs` 导出 BlobSource、CachedSource、openDatabase、异步扫描与检查，`node.mjs` 导出 Node 22 文件范围源。格式解码、结构检查与 WAL checksum 使用同一 MoonBit 核心。

第三方源为 `{size: bigint, async read(offset, count, {signal}), async close()}`，读取返回严格长度的 Uint8Array。默认接管输入源，失败时关闭；`closeSources: false` 保留原始源，由调用者自行管理。

```js
import {openDatabase} from '@prowk/moonsqlitefile-async';
import {openFileSource} from '@prowk/moonsqlitefile-async/node';

const db = await openDatabase(await openFileSource('copy.sqlite'));
try {
  const report = await db.inspectDatabase();
  console.log(report.inspection.status, report.summary);
} finally {
  await db.close();
}
```

`db.scan(root)` 支持 for await 背压与 break；`db.scanBtree` 等待异步 visitor；`schema`、`inspectPage`、`inspectDatabase` 返回进度/完整状态与部分结果。支持 AbortSignal 取消。所有成功记录/页面仍完整解码，有界缓存不代表整个检查为常量内存。

可选打开参数包括 wal、tailPolicy（strict/valid_prefix）、max_frames、max_overlay_pages，以及页数、记录数、单条/累计 payload、路径深度及报告预算。db/WAL 必须为同一时刻不可变副本，未实现在线锁或 SQL 执行。完整契约和本地验收见仓库 `docs/async-source.md`。
