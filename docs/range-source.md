# 同步范围读取（v0.6.0）

`RangeSource` 将文件长度及读取偏移改为 `Int64`，每次请求的字节数保留 `Int`。`open_range_source` 与 `open_range_wal_source` 返回原有 `Database`，继续使用页面、记录、扫描和检查 API。核心只依赖标准库，宿主负责文件句柄及静态副本，不提供在线锁、异步 I/O 或 checkpoint。

## 接口与地址边界

```moonbit
pub(open) trait RangeSource {
  fn byte_length64(Self) -> Int64
  fn read_range64(Self, Int64, Int) -> Bytes raise SourceError
}
```

长度必须非负，读取范围为 `[offset, offset + count)`，成功时必须返回恰好 `count` 字节。EOF 处允许零长度读取。核心先比较 `count <= size - offset`，再进行加法；数据库页偏移先转 `Int64`，再做乘法。调用者不得在读取期间改变源，缓存尤其依赖此约定。

`Database` 页号、记录位置和已有页归属类型继续使用 `Int`，本版最多支持 2147483647 页；更高页数或页指针显式返回错误，不将其截断为负数。文件字节偏移可超过 2 GiB，最大页长为 65536。新 WAL 报告的 `RangeWalFrame.byte_offset`、`stop_offset` 和 `trailing_bytes` 使用 `Int64`；`WalFrame` 等 v0.5 报告保持原结构。

`BytesSource` 同时实现两套接口。`PageSourceAdapter.new(old_source)` 将旧源用于新入口，但无法让旧源获得大文件能力。旧 `PageSource`、`open_source`、`WalSource` 和所有字节入口保留原签名。

`Database.source64()` 返回可用于完整读取的范围源。公开的旧 `Database.source` 字段仍为 `&PageSource`：旧入口保留原源；范围入口提供旧接口视图。源长度超过 Int 时，旧视图的 `byte_length()` 返回 -1，`read_range()` 抛出 `LimitExceeded`，要求改用 `source64()`；不会返回一个静默截断的文件。已有公开字段和报告的外部读取、解构、构造及枚举穷举均有消费验证。

## 读取失败与报告状态

`SourceError` 独立于格式错误，允许宿主构造 `HostFailure(message)`、`ShortRead(message)`、`RangeOutOfBounds(message)`。核心也检测短读与源范围越界。`PageSourceAdapter` 先核对完整范围，再直接调用旧源；只有旧源实际抛出的错误归为 HostFailure，返回长度不符归为 ShortRead，不从消息字符串猜测错误来源。

Database 的已有方法继续抛出 `SqliteError`，不增加其枚举分支。新入口将宿主错误映射为 `Unsupported`，消息以 `source/host_failure:`、`source/short_read:` 或 `source/range_out_of_bounds:` 开头。因此单页、树和全局报告均为 `Incomplete`，详细报告保留 `ReadPage` 阶段和已解码进度；取得完整页面后的格式错误仍为 `Invalid` / `Failed`。WAL 初始化时的宿主读取失败直接抛出，不因 `UseValidPrefix` 返回更早快照。

旧 `open_source` 的宿主 `SqliteError` 原样传播，保持历史状态语义；要使用统一的宿主失败分类，可经 `PageSourceAdapter` 切换至新入口。初始化失败尚未创建检查报告。`Complete` 仍只表示当前声明检查范围完成。

## 缓存、索引和报告预算

`CachedSource.new(source, block_size=4096, max_pages=256)` 以固定块缓存范围读取，采用 FIFO 淘汰。块大小 1–65536，容量 1–1048576；未读取的块不分配空间，最后一块只读取实际剩余字节。跨块结果按请求长度组装，淘汰块再次读取，短读或失败不进入缓存。`statistics()` 返回命中、未命中、宿主读取字节数和当前块数。

| 内存来源 | 控制方式 | 边界 |
| --- | --- | --- |
| 主文件缓存 | `block_size × max_pages` | CLI 默认 4096 × 256，约 1 MiB，不含结果缓冲及运行时开销 |
| WAL 读取缓冲 | 每次一个 `24 + page_size` 字节帧 | 不保留 WAL 全文件字节；开启源仍必须顺序扫描连续有效帧 |
| WAL 帧和提交报告 | `max_frames`，默认 100000 | O(有效帧数)，每帧仅保存元数据；预算耗尽不得当作最新快照 |
| WAL 覆盖页索引 | `max_overlay_pages`，默认 100000 | O(保留页数)，与帧预算分开；反向处理提交缩小和重新增长 |
| 遍历状态 | `Limits.max_pages`、`max_depth` | 保留已访问页以检测环、重复引用；遍历栈还保存当前路径页面 |
| 全局页归属和未知页报告 | 新入口 `max_report_pages`，默认 100000 | 实际上限同时受 `Limits.max_pages` 约束；逻辑页数超限时预检返回 Incomplete 和空页列表 |
| 诊断 | `max_issues`，默认 100 | 详细位置与诊断同步截断 |
| 记录结果及 payload | `max_rows`、单条及累计 payload 预算 | 单条仍完整组装解码；集合 API 和调用者保留的结果继续占用内存 |

这些是数量预算，不能解释为精确堆内存上限。64 位寻址和页缓存不会使全局检查成为常量内存；只需要记录前缀时使用 `scan_btree` 的回调和提前停止。

## CLI 与静态文件

CLI 选项、累计预算的适用命令、输出类型和 I/O 统计集中在[使用指南](usage.md#资源选项与输出)。本专题只维护范围源契约。

## 验收与成本复现

范围、缓存、SQLite 对照和高位 WAL 均纳入[完整验证](../CONTRIBUTING.md#完整验证)。固定规模样本与复现命令见[I/O 基准](io-benchmark.md)，历史规模和结果见[v0.8.0 验证记录](validation-v0.8.0.md)。稀疏寻址输入含未初始化页，不能作为合法大库全量检查证据。
