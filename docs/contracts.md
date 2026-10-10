# 错误、报告与兼容承诺

下列错误与报告契约适用于 v0.8.1。核心、同步源与异步宿主继续分层，不从消息字符串猜测错误类别或诊断位置。

## 程序化错误

异步包的 `errorInfo(error)` 返回 `{category, kind, message}`。`category` 固定为下表的六种类别；消息用于展示，不作为判别协议。

| category | 来源及处理 |
| --- | --- |
| argument | `ParameterError`，kind 为 `invalid_argument`；它仍继承 TypeError。修正页号、预算或类型后重试。 |
| corruption | 核心 `SqliteError('invalid', ...)`；展示诊断位置，保留已观察证据。 |
| source | `SourceError` 的 `host_failure`、`short_read`、`range_out_of_bounds`，或未知宿主/回调异常；重新选择不可变副本或修复读取实现。 |
| budget | 核心 `limit_exceeded`，或扫描摘要 `record_limit`；提高对应预算后重试。 |
| cancelled | `CancelledError`，kind 为 `cancelled`；可以重新发起操作。 |
| unsupported | 核心 `unsupported` 或 `unsupported_feature` 诊断；不能当作损坏。 |

未知外部异常归为 source；应用自身的业务错误仍应由应用处理。关闭失败会拒绝 Promise，WAL 配对关闭失败可能为 AggregateError；不能将其解释为文件损坏。打开失败没有 Database 报告，默认释放接管源；`closeSources: false` 时应用负责释放。

visitor/进度回调异常的来源由调用边界确定，自带 kind 不改变宿主分类；cause 保留原异常。`errorInfo` 单独转换已知错误或可信描述，不足以鉴别任意外部对象的真实来源。数据库及接管源重复关闭共享 Promise，包括同一次失败。

同步核心保留公开 `SqliteError` 的 Invalid、Unsupported、LimitExceeded 分支，以及 `SourceError` 的 HostFailure、ShortRead、RangeOutOfBounds 分支。旧 `PageSource` 保留 Int 寻址及原错误映射；宿主抛 Invalid 的历史行为无法单凭枚举判断损坏。v0.8.1 继续保留旧入口，不替换枚举或删除接口。新接入使用 `RangeSource` 或 `PageSourceAdapter`，在源边界直接匹配 SourceError；诊断通过 `DiagnosticPhase` 和 `DiagnosticLocation` 匹配实际阶段。范围源进入旧报告时仍保留历史 Unsupported 映射；[范围源说明](range-source.md)记录该兼容边界。不要从 `source/` 文本推断程序行为。

## 完成度与导出

`complete` 表示声明范围内完成；`incomplete` 表示预算、读取、取消、提前停止或能力边界导致未完成；`failed` 表示已发现声明范围内的格式/结构错误。已发现损坏后再遇到预算或读取失败，报告仍可能为 failed，覆盖标志继续反映未完成。所有状态都可能带已观察结果；未完成的 schema entries 仅为前缀，归属不完整时不能推断未认领页用途。Complete 不等同于 SQLite integrity_check。

`reportEnvelope(result, {scope, budgets})` 提供独立导出格式：`format: 'moonsqlitefile-report'`、`format_version: 1`、`tool_version`、`scope`、实际预算、`status`、`partial`、带 `category/kind/code/location` 的 diagnostics 及原始 result。范围包括 schema、database_structure、page 或 records，由调用者明确填写。预算字段是本次参数，不是恒定内存承诺。

包装同一次异步全库报告时，宿主失败类别来自捕获的 SourceError，取消来自实际 AbortSignal，不解析错误前缀。请在序列化/克隆原始报告之前包装；克隆后的历史 JSON 已丢失宿主异常的类型，不足以还原该类别。包装结果可直接 JSON.stringify；原 `inspectDatabase()` 的字段和 CLI 输出保持，未将新字段静默加入已发布 JSON。

先 reportEnvelope，再 JSON.stringify、structuredClone 或 Worker.postMessage；包装后的 diagnostics 随结果传输，不依赖 WeakMap。诊断截断时仍保留捕获的停止来源，不覆盖此前损坏；多个来源失败可同时存在，partial 与 failed 可同时成立。

预览游标暂停时为 incomplete / preview_paused，继续读取复用同一游标；消费者 break 为 visitor_stopped，数量预算为 record_limit。展示截断只影响界面文字，单条记录仍完整解码并受 payload 预算限制。原始值按磁盘存储顺序排列，不能当成 WITHOUT ROWID 或索引的 SQL 列顺序。

查看器在创建游标时冻结实际数量、累计 payload 和时间预算；续读预算变化必须重新预览。schema/预览数量不超过打开时 max_rows，报告同时保留请求上限与实际上限。展示字段/字符和大值批次限制在 Worker 传输前执行，库返回值保持完整；具体界限见[查看器说明](../examples/offline-viewer/README.md#记录预览与导出)。

## 64 位值

异步与 CLI 的 rowid、integer 值、累计 payload 均为十进制字符串；源长度和读偏移使用 bigint。异步范围请求和覆盖索引定位的偏移为十进制字符串。实数是 JSON number，非有限值分别为字符串 NaN、Infinity、-Infinity；blob 为十六进制文本，null 为 JSON null。

WAL 检查报告中的 frames[].byte_offset、stop_offset、trailing_bytes 在异步和 CLI 两个入口均保留已发布规则：安全整数范围内为 JSON number，超出 9007199254740991 时为十进制字符串。不要将 WAL 报告字段与异步读事件偏移混淆。消费方应按字段契约解析；历史 CLI 契约仍由正式版本基线校验，不为了统一类型改写旧输出。

## 兼容与资源

公开函数、类型构造、枚举匹配、字段、JSON 与退出码都属于契约。新增枚举分支或结构字段不自动视作兼容；有变更时提供迁移说明，并保留历史基线。核心只依赖标准库；宿主快照一致性、生命周期、各项独立预算和支持范围见[支持说明](support.md)、[异步指南](async-source.md)及[WAL 契约](wal.md)。
