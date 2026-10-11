# 异步范围读取与浏览器适配

MoonBit 核心继续只依赖标准库。异步宿主位于独立 JS 包 `adapters/async`，扫描、record/overflow、页归属、freelist、Ptrmap 和 WAL checksum 仍由同一核心状态机完成。同步入口也驱动这些状态机，不在 JavaScript 重写格式解析。

当前版本为 v0.8.1，发布状态与安装附件见[对应 Release](https://github.com/prowk/MoonSQLiteFile/releases/tag/v0.8.1)。导出/原型持续对照正式 v0.7.0 和 v0.8.0，支持范围见[支持矩阵](support.md)。

## 本地构建与消费

异步包以 v0.8.1 Release 的 `prowk-moonsqlitefile-async-0.8.1.tgz` 附件分发，下载后执行 `npm install ./prowk-moonsqlitefile-async-0.8.1.tgz`，也可按下文从源码构建。该包尚未上传 npm registry。

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

Database、CachedSource、WalSource 和 Node 文件源的重复 `close()` 共享同一个 Promise，全部调用者等待同一次资源释放。关闭开始后拒绝新数据库操作；关闭失败后重复调用仍拒绝同一个错误，不自动重试。WAL 两个宿主均会尝试关闭，同步抛错不会阻止另一方清理。

无效缓存选项或 WAL 源构造失败也会关闭已接管输入。配对关闭会尝试两个宿主；宿主的 close 自身失败时，`db.close()` 拒绝并报告异常，而不是隐藏它。打开失败时清理所有已接管源，并保留最初的打开错误。

## 扫描、背压和部分结果

- `db.scan(root, options)` 是异步迭代器。一次 `next()` 最多返回一条记录；消费者等待时不预读后续记录。同一迭代器不能并发调用 `next()`。`break` 会终止游标，`scan.result` 保存摘要。
- `db.scanBtree(root, asyncVisitor, options)` 等待 visitor 完成后再继续；visitor 返回 false 提前停止，visitor 的 signal 来自扫描。它返回报告；读取/解析失败保存进度与可用位置，而不是伪造完整结果。visitor 自身异常为未完成报告。
- `db.schema(options)` 返回 `entries` 和扫描状态；错误或预算不足时 entries 只代表已经解码的前缀。
- `db.inspectPage(page, {signal})` 与同步页检查使用同一核心，页读取失败保持 incomplete。
- `db.inspectDatabase(options)` 返回 `{header, inspection, summary, locations}`；格式错误为 failed，读取失败/预算不足为 incomplete。取消额外返回 `reason: 'cancelled'`，保留已观察页、记录和诊断。读取失败后可继续检查独立对象，schema 未完成时无法继续发现全部根页。

扫描支持 `limit`、`max_total_payload_bytes`（BigInt 或十进制文本）、`signal`、`onProgress`；全库检查还支持 `max_issues`。默认累计 payload 为 67108864 字节；打开选项 `max_payload_bytes` 默认单条 16777216，`max_rows`/`max_pages`/`max_report_pages` 默认各 100000，`max_depth` 默认 64。达到记录 limit 的报告为 `record_limit`，手动停止为 `visitor_stopped`。全库 payload 统计为已请求量，失败记录可能已计费；不能把它解释为成功记录的字节总和。

页号必须为整数 number，范围为 1 到逻辑页数（最多 2147483647）。Int32 预算必须为 1–2147483647 的整数 number，扫描 `limit` 允许 0 且不能超过 `max_rows`；缓存范围另见上文。小数、NaN、Infinity、字符串、BigInt、null 和越界值不会被截断或转换；扫描/预算类型错误抛 TypeError，`inspectPage` 继续以 incomplete 报告非法页号。累计 payload 必须为 0–18446744073709551615 的 BigInt 或纯十进制文本。参数错误发生在创建游标和额外读取之前；打开失败仍按源接管规则清理。既有错误参数的升级影响见[升级说明](migration.md#v081)。

核心调用是同步 CPU 工作：每个供页最多解析一个完整页，每条 record 仍完整解码。适配器定期让出事件循环，并在读取/visitor 等待时响应取消。任意同步 JavaScript visitor 或单次核心调用不能被 AbortSignal 强制抢占。

取消参数只接受真实 AbortSignal 或省略；null、0、普通对象及仿造 signal 均按 ParameterError 拒绝，无效参数不增加 I/O。`inspectPage` 保留 incomplete 返回协议，错误信息中的 kind 为 invalid_argument。visitor 和进度回调异常在宿主边界转换为 SourceError(host_failure)，原异常保存在 cause；即使它自带 invalid、unsupported 或 cancelled 等 kind，也不代表核心损坏、能力边界或实际取消。

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

## 有限字段与 BLOB 分块（未发布）

`Database.scanProjected(root, options)` 返回 `ProjectedRecord`，`previewRecord({page_number, cell_offset}, options)` 独立读取同一静态快照中的定位。`header.fields` 保留物理序号、serial type、payload 内字节偏移和原长度；`values` 仅含所选字段，按物理序号排序。`fields` 缺省取前 `max_selected_fields` 列（128），空数组只读头。它们不提供 SQL 列名、亲和性或行查询。

例如 `db.scanProjected(2, {fields: [0, 2], max_field_bytes: 256, max_total_copy_bytes: 1048576n})`；取得记录后使用 `await db.readBlobChunk(record, 2, {offset: 0, length: 65536})`。分块 `bytes` 是独立 `Uint8Array`，`more` 指示字段后部仍有字节；偏移、长度和原长度都以原始字节计数。分块不限定页面边界。定位在扫描前进、暂停、结束后仍有效，前提是数据库保持打开且源不变。数据库关闭后不能再次读取；已经返回的值和字节仍可使用。每次调用拥有独立供页游标，可取消，关闭数据库会取消并等待正在读取的操作，然后释放句柄和源。

文本/BLOB 前缀默认 256、可设 0–65536 原始字节；整数、浮点和空值完整解码，最多 8 字节，不按字符数截断。UTF-8 退回完整码点，UTF-16 退回完整 2 字节单元且不留下半个代理对；已读不合法编码会失败，未读尾部不解码。`returned_bytes` 表示交付原始字节数，`truncated` 表示交付长度小于原长度。BLOB chunk 的 `length` 同为 0–65536，越过字段末尾返回剩余字节，起点等于末尾返回空，越界拒绝。

默认头预算 65536 字节（范围 9–65536）、总字段 2048（1–65536）、选取字段 128（0–max_fields，选择数组不得超限或重复；总字段上限设得更小时须同时降低选择上限）。先检查头长、字段数和选择数量，再分配相应数组/值。默认累计复制预算 64 MiB，`max_total_copy_bytes` 含初始探测（最多 9 字节）、记录头以及所选前缀/分块，边界裁掉的少数字节也计费；单次读取重新计费，扫描跨条累计。投影的 `progress.payload_bytes` 指该计费量。区间在分配前计费，读取失败或取消不退还，因此停止进度可能包含尚未供完的区间，不等同于成功交付字节数。`max_payload_bytes` 与 `max_total_payload_bytes` 继续约束旧完整读取；不能用它们推断新投影的复制限制。

`record_complete` 仅在全部字段完整解码且链完整时为真；`overflow_chain_complete` 表示实际观察到的链完整，不能代替字段内容校验。投影扫描 `status: complete` 表示树遍历结束，`records_complete: false` 的报告仍为 `partial: true`。短预览、未选字段或未读链尾都没有因此验证；需要全内容与全库检查时仍用原 API。有限读取可预览超过完整读取单条上限的字段，但仍受现有 payload 整数寻址、页/深度预算、头预算和复制预算约束。

核心对应 `parse_record_header`、`Database.field_cursor`、`blob_chunk_cursor`、`projected_cursor`；宿主用 `next/provide_page/stop` 驱动，不包含 I/O。停止或失败后不再索取页，成功值独立于游标。完整 `decode_record`、BTreeCursor 和扫描签名保持兼容。

分块访问后部会从前面的 overflow 指针逐页前进，重复分块可能重复读链；不是 O(1) 随机 I/O。页缓冲、记录头、所访问页的归属/循环集合、遍历路径、宿主缓存和 WAL 索引仍占内存。复制预算计字段读取量，不是全部宿主/桥接分配总量；桥接还将有限 BLOB 转成十六进制，分块适配再生成字节数组。未选字段避免整值复制/解码，但选后部字段仍可能读取前部所有页。

## 类型与结构化报告

本地 tarball 包含 index.d.ts、node.d.ts 及条件导出，支持严格 NodeNext 与 Bundler 消费；Node 子入口不向浏览器暴露。包内 example-node.mjs 与 example-browser.mjs 分别从真实安装包运行静态 db/WAL、源接管、异步迭代和关闭。先 npm pack ./_build/async-adapter，再 npm install 对应本地 tgz；npm registry 尚未发布。

新增 ParameterError 继承 TypeError，kind 为 invalid_argument；errorInfo 提供稳定类别，reportEnvelope 在原始 JSON 外包装范围、实际预算、完成度及诊断。读取报告的宿主失败来源由同次运行捕获，不依赖消息前缀；请在克隆或序列化原报告之前包装。完整规则见[错误与报告契约](contracts.md)，页号越界分类变化见[升级说明](migration.md#v081)。


summary、页面结果、issue 和 WAL 声明提供常用命名字段及可判别联合；WAL 报告偏移仍为 number 或十进制文本。低层 Database/WalSource 构造器仅支持真实核心桥接和其生成句柄，常规接入使用 openDatabase。类型收紧可能暴露原消费代码的错误访问，见迁移说明。
