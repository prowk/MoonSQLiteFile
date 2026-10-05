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

Node CLI 以只读文件描述符、BigInt 文件长度和范围读取运行，退出时关闭主文件及 WAL 句柄。每次实际 I/O 核对长度、mtime/ctime，检测到变化即报告宿主失败；这项检测不构成在线一致性或文件身份保证。页缓存命中不会重新核对宿主，所以输入仍必须是真正不可变的副本。

```sh
moon build --target js src/cmd/inspect
node tools/inspect.cjs large.sqlite --cache-pages 64 --io-stats scan 2
node tools/inspect.cjs snapshot.db --wal snapshot.wal --max-frames 200000 --max-overlay-pages 100000 header
node tools/inspect.cjs large.sqlite --max-pages 200000 --max-report-pages 150000 --max-issues 100 inspect-details
```

选项放在文件名之后、命令之前；还可设置 `--max-rows`。

`--max-payload-bytes` 控制单条记录，默认 16777216，接受 1–2147483647 的十进制整数。`--max-total-payload-bytes` 控制扫描累计预算，默认 67108864，接受 0–18446744073709551615 的十进制整数；宿主使用 BigInt，桥接到 UInt64，不经 Number 舍入。累计预算传给 `scan`、`tree-inspect`、`inspect`、`inspect-details`、`summary`、`summary-json` 和 `viewer-data`；全局检查包含 schema 消耗。0 是有效预算，用于明确拒绝任何 payload 消耗。

```sh
node tools/inspect.cjs large.sqlite --max-total-payload-bytes 134217728 scan 2
node tools/inspect.cjs large.sqlite --max-payload-bytes 33554432 --max-total-payload-bytes 134217728 summary-json
```

`rows`、`records`、`index` 和 `schema` 使用已有集合 API，仅受记录数、页数及单条 payload 上限控制；上述累计选项不改变集合 API 的契约，也不限制生成的数组或 JSON 总大小。大结果应改用 `scan`，集合命令应显式传入较小的 LIMIT；页数、报告页数和 payload 是相互独立的预算。

`--io-stats` 单独在 stderr 输出读取次数、字节数、最大请求及进程峰值 RSS/耗时，不改变 stdout JSON。RSS 使用 Node `resourceUsage().maxRSS`，包含运行时、加载的代码、缓冲、报告和输出，不是核心独占内存。

WAL CLI 保持原 JSON 字段及通常的数值类型；64 位偏移在 JavaScript 精确整数范围内仍为 JSON 数字，超出 9007199254740991 时为十进制字符串。标准 WAL 帧预算下的偏移远小于此边界。

v0.6.0 的历史离线 HTML 使用内存字节输入、64 MiB 和 30 秒限制。v0.7.0 本地源码改为独立异步适配器与 Blob 分块读取，支持 db/WAL、取消、进度和部分结果，详见[异步契约](async-source.md)。

## 验收与成本复现

```sh
moon test --target all --deny-warn
python tools/verify_review.py
node tools/verify_range_io.cjs
node tools/verify_wide_wal.cjs
python tools/verify_large_payload.py
python tools/verify_wal_oracle.py
python tools/benchmark_io.py
```

四后端虚拟源覆盖 2 GiB、最大 Int 页号、长度乘法、短读和宿主失败；真实稀疏文件验证 2147483648 字节处的末页，读取两次、共 4608 字节。该稀疏文件只用于寻址验收，含未初始化的中间页，不是合法完整 SQLite 数据库。Windows 先以 `fsutil sparse setflag` 标记，POSIX 使用稀疏截断；不能创建 sparse 时验收失败，不以大量实际分配或跳过替代。

`verify_review.py` 用 SQLite 生成 54 组 CREATE/INSERT/DELETE/UPDATE 序列，独立核对合法结构及记录，同时断言空子页损坏被拒绝。现有 WAL oracle 继续核对 29 个快照、双 checksum 字节序、未提交尾部、reset、缩小/增长及输入不被改写。范围文件输入与内存入口逐命令比对 JSON。

持续 fuzz 对每个固定种子输入比较旧入口、范围入口、适配器以及两种源的缓存开关，核对完整诊断和进度；注入短读与宿主抛错，检查缓存不保留失败数据、报告保持 Incomplete、WAL 有效前缀策略不能吞掉宿主失败。旧入口的 Int 长度上限及不足 100 字节输入的历史分类单独核对；其余同范围报告要求一致。失败样本仍按同一种子/页号/配对主文件重放。

`verify_wide_wal.cjs` 在 JS 按需生成 32769 个有效 65536 字节帧，逐帧校验并创建覆盖索引，最后实际读取偏移 2148270136 的页面头；虚拟长度为 2148335672，不保存整个日志。四后端白盒边界回归隔离覆盖索引读取，在该偏移和 4294967320 处读取整页及页内切片；全帧 checksum 与实际索引创建由 JS 扩展验收覆盖，两类证据不混为一项。

`verify_large_payload.py` 生成经 SQLite integrity_check 确认的 1100 行 BLOB 数据库，累计 payload 为 72094000 字节，默认扫描失败、全局检查 Incomplete；显式增额后上述七类命令完整完成。另验证 17 MiB 单条记录、零累计预算、UInt64 最大值及超过 JS 精确整数范围的值、溢出/格式/重复参数拒绝。CI 执行这些扩展验收并保存 JSON 证据。Linux 的归属验收强制要求 SQLite dbstat，并记录实际对照页数；缺少模块时失败。Windows 未启用 dbstat 时只记录本机完成的其余对照，不把它记为物理页对照通过。

固定规模的扫描、全局检查和 WAL 打开记录见[同步 I/O 基准](io-benchmark.md)。
