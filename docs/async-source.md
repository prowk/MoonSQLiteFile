# 异步范围读取与浏览器适配

MoonBit 核心继续只依赖标准库。异步宿主位于独立 JS 包 `adapters/async`，扫描、record/overflow、页归属、freelist、Ptrmap 和 WAL checksum 仍由同一核心状态机完成。同步入口也驱动这些状态机，不在 JavaScript 重写格式解析。

当前源码用于 v0.8.1 开发，尚未发布；已发布的附件仍为 v0.8.0。导出/原型持续对照正式 v0.7.0 和 v0.8.0，支持范围见[支持矩阵](support.md)。

## 本地构建与消费

异步包随 v0.8.0 Release 以 `prowk-moonsqlitefile-async-0.8.0.tgz` 附件提供，下载后执行 `npm install ./prowk-moonsqlitefile-async-0.8.0.tgz`，也可按下文从源码构建。该包尚未上传 npm registry。

```sh
moon build --target js --deny-warn
python tools/build_async.py
node adapters/async/example.mjs fixtures/core.sqlite
```

构建结果在 `_build/async-adapter`，包含 `package.json`、`index.mjs`、`node.mjs` 和编译的 `core.mjs`。可将整个目录作为本地依赖，或使用 `npm pack ./_build/async-adapter` 生成 tarball。包名为 `@prowk/moonsqlitefile-async`，运行时没有第三方依赖；不要只复制 `index.mjs`。

```js
import {openDatabase} from './_build/async-adapter/index.mjs';
import {openFileSource} from './_build/async-adapter/node.mjs';

const db = await openDatabase(await openFileSource('copy.sqlite'));
try {
  const schema = await db.schema();
  if (schema.status !== 'complete') throw new Error(schema.reason);
  const root = schema.entries.find(entry => entry.name === 'samples').root_page;
  const scan = db.scan(root);
  for await (const record of scan) {
    console.log(record.rowid, record.page_number, record.values);
  }
  console.log(scan.result);
} finally {
  await db.close();
}
```

`package.json` 导出包入口及 `/node` 子路径。Node 入口只用于 Node，不在浏览器加载它。

## 数据源和生命周期

第三方异步源提供 `size: bigint`、`read(offset: bigint, count: number, {signal})` 和可选异步 `close()`。长度/偏移必须在非负有符号 64 位范围内，count 必须是非负 Int32；成功时返回长度恰好等于 count 的 `Uint8Array`。源须保持不可变，并负责自己的宿主操作及关闭协议。

`readExact` 在调用前验证范围并在返回后验证短读。`SourceError.kind` 为 `range_out_of_bounds`、`short_read` 或 `host_failure`；未知宿主抛错归为 `host_failure`。`CancelledError.kind` 为 `cancelled`。取消不会被当作文件损坏，也不把 WAL 读取失败当作可用的异常尾部。

`BlobSource` 每次只读取 `blob.slice()` 的范围；`openFileSource` 使用 BigInt 文件位置，检查实际读取时的长度/时间戳，并在关闭时等候自己的在途系统读取结束。它不是在线 SQLite 锁或快照协议。

`CachedSource` 为固定块 FIFO 缓存，默认 4096 字节 × 256 块。返回副本，失败及取消的数据不进入缓存；`statistics` 包含命中/未命中、实际读入字节及驻留块数。可设置 `blockSize`（1–65536）及 `cachePages`（1–1048576）。缓存不会使路径状态、payload、WAL 索引或全库归属报告成为常量内存。

`openDatabase` 默认接管输入源并在失败或 `db.close()` 时关闭。设置 `closeSources: false` 时只释放适配器缓存与核心句柄，原始源由调用者管理。`close()` 会取消当前操作，停止游标并释放核心句柄；调用者始终应使用 `finally`。宿主不响应 signal 的底层操作可能继续完成，但取消后的结果不会再供应给核心。

无效缓存选项或 WAL 源构造失败也会关闭已接管输入。配对关闭会尝试两个宿主；宿主的 close 自身失败时，`db.close()` 拒绝并报告异常，而不是隐藏它。打开失败时清理所有已接管源，并保留最初的打开错误。

## 扫描、背压和部分结果

- `db.scan(root, options)` 是异步迭代器。一次 `next()` 最多返回一条记录；消费者等待时不预读后续记录。同一迭代器不能并发调用 `next()`。`break` 会终止游标，`scan.result` 保存摘要。
- `db.scanBtree(root, asyncVisitor, options)` 等待 visitor 完成后再继续；visitor 返回 false 提前停止，visitor 的 signal 来自扫描。它返回报告；读取/解析失败保存进度与可用位置，而不是伪造完整结果。visitor 自身异常为未完成报告。
- `db.schema(options)` 返回 `entries` 和扫描状态；错误或预算不足时 entries 只代表已经解码的前缀。
- `db.inspectPage(page, {signal})` 与同步页检查使用同一核心，页读取失败保持 incomplete。
- `db.inspectDatabase(options)` 返回 `{header, inspection, summary, locations}`；格式错误为 failed，读取失败/预算不足为 incomplete。取消额外返回 `reason: 'cancelled'`，保留已观察页、记录和诊断。读取失败后可继续检查独立对象，schema 未完成时无法继续发现全部根页。

扫描支持 `limit`、`max_total_payload_bytes`（BigInt 或十进制文本）、`signal`、`onProgress`；全库检查还支持 `max_issues`。默认累计 payload 为 67108864 字节；打开选项 `max_payload_bytes` 默认单条 16777216，`max_rows`/`max_pages`/`max_report_pages` 默认各 100000，`max_depth` 默认 64。达到记录 limit 的报告为 `record_limit`，手动停止为 `visitor_stopped`。全库 payload 统计为已请求量，失败记录可能已计费；不能把它解释为成功记录的字节总和。

页号必须为整数 number，范围为 1 到逻辑页数（最多 2147483647）。Int32 预算必须为 1–2147483647 的整数 number，扫描 `limit` 允许 0 且不能超过 `max_rows`；缓存范围另见上文。小数、NaN、Infinity、字符串、BigInt、null 和越界值不会被截断或转换；扫描/预算类型错误抛 TypeError，`inspectPage` 继续以 incomplete 报告非法页号。累计 payload 必须为 0–18446744073709551615 的 BigInt 或纯十进制文本。参数错误发生在创建游标和额外读取之前；打开失败仍按源接管规则清理。既有错误参数的升级影响见[待发布升级说明](migration.md#unreleased)。

核心调用是同步 CPU 工作：每个供页最多解析一个完整页，每条 record 仍完整解码。适配器定期让出事件循环，并在读取/visitor 等待时响应取消。任意同步 JavaScript visitor 或单次核心调用不能被 AbortSignal 强制抢占。

## db/WAL 静态快照

```js
const db = await openDatabase(await openFileSource('copy.sqlite'), {
  wal: await openFileSource('copy.wal'),
  tailPolicy: 'strict', // 异常尾部默认拒绝；需要时显式改为 valid_prefix
  max_frames: 100000,
  max_overlay_pages: 100000,
});
```

上例的两项注释应在业务代码中按静态副本责任使用。应用应对打开第二个源前的失败也负责释放已打开的第一个源。库接收到两者后负责其生命周期。WAL 逐帧校验；校验完整后由核心生成覆盖索引，并按最新提交逻辑页数打开快照。未提交尾帧、缩小/增长和异常尾部策略与同步一致。帧数或覆盖页预算不足不会成功返回更旧快照。WAL 报告偏移在安全整数范围内仍为 number，超出时使用十进制文本；异步范围事件与覆盖索引的偏移始终为文本。详见[64 位契约](contracts.md#64-位值)。

取消或打开失败时没有可用的 Database。`onProgress` 可以观察已经校验的帧数；不能把未完成的帧前缀称为最新已提交快照。

## 离线查看器与验收范围

`python tools/build_viewer.py` 将核心、适配器、Worker、界面和示例库嵌入单个 HTML，不包含外部脚本、样式、网络请求或服务依赖。主线程将 File/Blob 传给 Worker，保留一个静态快照；导航只接收当前页字节，不复制整个数据库。

取消可保留部分全库报告；切换文件关闭旧 Worker 快照，拒绝旧任务响应，释放句柄并终止旧 Worker。界面提供可选 WAL、显式有效前缀策略，以及页数、记录数、累计 payload 和时间预算。默认 64 MiB 累计 payload、120 秒；移除原 64 MiB **文件长度**硬限制。输入文件大小与资源预算是不同约束。

浏览器启动方式和宿主范围集中在[支持说明](support.md#浏览器启动方式)。历史规模、时间及截图见[v0.8.0 验证记录](validation-v0.8.0.md)；本专题不将历史结果当作未来版本证据。

公开 MoonBit `BTreeCursor`、`WalCursor`、`InspectionCursor` 自身不执行 I/O。调用者驱动 `next()`，按事件供页/供范围，再消费记录/报告；不要把未完成或取消的 WalCursor 用作最新快照。`RangeWalSource.from_cursor` 的源必须与校验时相同且不可变。其 `page_range` 查询实际页来源，宿主只执行范围读取，不重新实现覆盖规则。

完整复现使用[统一验证入口](../CONTRIBUTING.md#完整验证)。单项脚本仍可独立运行；参数、取消、背压、WAL、失败路径和释放纳入持续验收。

## 类型与结构化报告

本地 tarball 包含 index.d.ts、node.d.ts 及条件导出，支持严格 NodeNext 与 Bundler 消费；Node 子入口不向浏览器暴露。包内 example-node.mjs 与 example-browser.mjs 分别从真实安装包运行静态 db/WAL、源接管、异步迭代和关闭。先 npm pack ./_build/async-adapter，再 npm install 对应本地 tgz；npm registry 尚未发布。

新增 ParameterError 继承 TypeError，kind 为 invalid_argument；errorInfo 提供稳定类别，reportEnvelope 在原始 JSON 外包装范围、实际预算、完成度及诊断。读取报告的宿主失败来源由同次运行捕获，不依赖消息前缀；请在克隆或序列化原报告之前包装。完整规则见[错误与报告契约](contracts.md)，页号越界分类变化见[升级说明](migration.md#unreleased)。


summary、页面结果、issue 和 WAL 声明提供常用命名字段及可判别联合；WAL 报告偏移仍为 number 或十进制文本。低层 Database/WalSource 构造器仅支持真实核心桥接和其生成句柄，常规接入使用 openDatabase。类型收紧可能暴露原消费代码的错误访问，见迁移说明。

Database、CachedSource、WalSource 和 Node 文件源的重复 `close()` 共享同一个 Promise，全部调用者等待同一次资源释放。关闭开始后拒绝新数据库操作；关闭失败后重复调用仍拒绝同一个错误，不自动重试。WAL 两个宿主均会尝试关闭，同步抛错不会阻止另一方清理。
