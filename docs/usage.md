# 使用指南

先按 [README](../README.md#安装) 安装并导入 `prowk/moonsqlitefile`。以下函数与首页的 `read_rows` 一起，在实际打包库的四后端独立消费项目中验证。示例路径和 CLI 命令均从仓库根目录运行。

## 表与索引记录

对于 WITHOUT ROWID 表或索引，使用原始记录 API：

```moonbit
fn read_records(data : Bytes) -> Array[@sqlite.BTreeRecord] raise @sqlite.SqliteError {
  let db = @sqlite.open_database(data)
  db.table_records("keyed", limit=10)
}

fn read_index(data : Bytes) -> Array[@sqlite.BTreeRecord] raise @sqlite.SqliteError {
  let db = @sqlite.open_database(data)
  db.index_records("mixed_index", limit=10)
}
```

`BTreeRecord` 额外提供 `cell_offset`；索引和 WITHOUT ROWID 记录的 `rowid` 为 `None`。这两个示例对应仓库中的 `fixtures/btree.sqlite`。

### 逐条扫描

用 `scan_btree` 消费记录，可避免在库中收集整个结果数组。根页号可从 `db.schema()` 的条目获取：

```moonbit
fn scan_records(
  data : Bytes,
  root_page : Int,
  consume : (@sqlite.BTreeRecord) -> Bool raise @sqlite.SqliteError,
) -> @sqlite.ScanSummary raise @sqlite.SqliteError {
  let db = @sqlite.open_database(data)
  db.scan_btree(root_page, consume, limit=1000, max_total_payload_bytes=8388608UL)
}
```

回调返回 `false` 时停止扫描。检查 `ScanSummary.completion`，区分 `Complete`（已遍历全部记录）、`RecordLimit`（达到记录上限）和 `VisitorStopped`（回调主动停止）。结果还提供已读取的记录数、页数及累计 payload 字节数。

### 按需读取

`open_source(&PageSource)` 接收宿主实现的数据源，初始化时仅读取文件头，后续按范围读取字节。接口同步返回 `Bytes`，数据源必须在整个读取期间保持同一份静态快照。接口定义和资源限额见 [架构说明](https://github.com/prowk/MoonSQLiteFile/blob/main/docs/architecture.md)。

### 检查数据库结构

```moonbit
fn inspect_file(data : Bytes) -> @sqlite.DatabaseInspection raise @sqlite.SqliteError {
  let db = @sqlite.open_database(data)
  db.inspect_database(max_total_payload_bytes=67108864UL, max_issues=100)
}
```

报告提供每页的用途、对象、根页和父页，以及冲突双方、未认领页和 Ptrmap 不一致等诊断。`status` 区分 `Complete`、`Incomplete` 和 `Failed`；`ownership_complete` 表示归属遍历完成，`ptrmap_checked` 表示反向指针检查完成或不适用，`diagnostics_truncated` 表示诊断已截断。达到资源限额时会保留已完成的结果；未完成根页发现时，不把未知页判定为孤儿。

只检查一棵树时使用 `db.inspect_btree(root_page)`；读取原始反向指针时使用 `db.ptrmap_entries()`。结构检查范围与各标记的含义详见 [架构说明](https://github.com/prowk/MoonSQLiteFile/blob/main/docs/architecture.md)。

### 读取 WAL 快照

```moonbit
fn read_committed(db_bytes : Bytes, wal_bytes : Bytes) -> @sqlite.Database raise @sqlite.SqliteError {
  @sqlite.open_wal_database(db_bytes, wal_bytes)
}
```

`inspect_wal` 提供帧/提交报告；`WalSource::new` 可包装第三方同步源，再用 `open_wal_source` 打开。默认拒绝异常尾部，显式 `UseValidPrefix` 才读取异常前的完整提交；帧预算不足不能当作最新快照成功。输入必须是同一时刻的一致静态副本，详见 [WAL 契约](wal.md)和[升级说明](migration.md#v050)。

## 命令行工具

CLI 使用[已验证的工具链与宿主](support.md)，无 npm 运行时依赖：

```sh
git clone https://github.com/prowk/MoonSQLiteFile.git
cd MoonSQLiteFile
moon build --target js src/cmd/inspect
node tools/inspect.cjs fixtures/core.sqlite schema
node tools/inspect.cjs fixtures/core.sqlite rows samples 10
node tools/inspect.cjs fixtures/btree.sqlite index mixed_index 5
node tools/inspect.cjs fixtures/btree.sqlite inspect
node tools/inspect.cjs fixtures/btree.sqlite summary
```

将样本路径替换为自己的静态数据库副本即可检查实际文件。所有命令的格式为 `node tools/inspect.cjs <file> <command> [arguments]`：

| 命令 | 用途 |
| --- | --- |
| `header` | 读取数据库文件头 |
| `schema` | 列出 schema 条目及根页号 |
| `page <number>` | 检查指定 B-tree 页 |
| `page-inspect <number>` | 返回 B-tree 页空间统计与错误位置 |
| `rows <table> [limit]` | 读取普通 rowid 表 |
| `records <table> [limit]` | 读取普通表或 WITHOUT ROWID 表的原始记录 |
| `index <name> [limit]` | 读取索引原始记录 |
| `scan <root> [limit]` | 扫描指定根页，输出记录和扫描状态 |
| `freelist` | 检查空闲页链 |
| `inspect` | 输出全局页归属、Ptrmap 校验及结构化诊断 |
| `tree-inspect <root> [limit]` | 输出单树检查进度和失败位置 |
| `inspect-details` | 输出全局报告及各条诊断的位置 |
| `summary` | 中文检查摘要、页面分类、对象占页及诊断 |
| `summary-json` | 精简 JSON 汇总，适合展示层消费 |
| `viewer-data` | 同一次扫描的文件头、汇总、详细诊断与导航数据 |
| `wal-inspect` | 输入为 WAL 文件，输出连续有效帧和提交边界 |
| `wal-info` | 配合 `--wal` 输出帧报告、最新快照页数与尾部策略 |

除 `summary` 输出中文文本外，成功时 stdout 输出一行 JSON；参数、初始化或读取错误写入 stderr，并返回非零退出码。能够构造报告的检查与摘要命令始终将报告写入 stdout：退出码 `0` 表示完整、`1` 表示失败、`2` 表示未完成，诊断与覆盖范围保留在报告中。整数和 rowid 输出为十进制字符串，BLOB 输出为十六进制字符串，避免 JavaScript 丢失 64 位整数精度。`rows` 默认上限为 100000 行，显式传入 `0` 返回空数组。

WAL 输入格式为 `node tools/inspect.cjs DB --wal WAL [--wal-prefix] COMMAND [arguments]`。选项放在命令前；原有命令都读取同一已提交覆盖视图。不提供 `--wal` 时继续只读主文件，不自动加载相邻日志。`wal-inspect` 直接接收 WAL 文件并以 0/1/2 区分 EOF/异常尾部/帧预算不足。示例：

```sh
node tools/inspect.cjs snapshot.wal wal-inspect
node tools/inspect.cjs snapshot.db --wal snapshot.wal wal-info
node tools/inspect.cjs snapshot.db --wal snapshot.wal inspect-details
```

异步源和浏览器操作分别见[异步适配](async-source.md)与[离线查看器](../examples/offline-viewer/README.md)。

## 资源选项与输出

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
