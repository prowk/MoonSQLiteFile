<div align="center">

# MoonSQLiteFile

[![CI](https://github.com/prowk/MoonSQLiteFile/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/prowk/MoonSQLiteFile/actions/workflows/ci.yml)
[![Mooncakes](https://img.shields.io/badge/Mooncakes-v0.7.0-2563eb)](https://mooncakes.io/docs/prowk/moonsqlitefile@0.7.0)
[![License](https://img.shields.io/badge/License-Apache--2.0-2563eb)](https://github.com/prowk/MoonSQLiteFile/blob/main/LICENSE)

**纯 MoonBit 的 SQLite 文件解析与检查库**

[API 文档](https://mooncakes.io/docs/prowk/moonsqlitefile@0.7.0) · [架构说明](https://github.com/prowk/MoonSQLiteFile/blob/main/docs/architecture.md) · [版本记录](https://github.com/prowk/MoonSQLiteFile/blob/main/CHANGELOG.md)

</div>

MoonSQLiteFile 直接读取 SQLite 3 数据库的磁盘格式，提供文件头、页面、schema 和原始记录的只读 API。适合构建离线数据库浏览器、文件结构检查工具，以及 SQLite 存储格式的教学演示。

核心库只依赖 MoonBit 标准库，支持 **Wasm、WasmGC、JavaScript 和 native**，无需 SQLite 引擎或 FFI。文件 I/O 由宿主提供；随附的 Node.js CLI 可直接检查本地数据库快照。

## 功能

- **文件与页面解析**：100 字节文件头、512–65536 字节页面、四类 B-tree 页、完整 cell/freeblock 空间覆盖与碎片计数校验。
- **记录解码**：1–9 字节 varint、标准 serial types、64 位整数、浮点、NULL、BLOB，以及 UTF-8、UTF-16LE、UTF-16BE 文本。
- **表与索引读取**：多层 rowid 表、索引内部页记录、WITHOUT ROWID 表、overflow 链及 `sqlite_schema`。
- **有界扫描**：逐条回调、提前停止、完成状态，以及记录数、树深度、页数和 payload 预算。
- **结构检查**：单树检查和全局页归属报告，检测跨对象重复占页、freelist 冲突、未认领页及 auto-vacuum Ptrmap 不一致。
- **WAL 快照**：两种 checksum 字节序、salt 与提交边界校验、只读覆盖数据源和最新已提交页版本；CLI 显式接收 db/WAL 一致副本。
- **宿主集成与展示**：`Bytes` 输入、第三方同步 `PageSource` / `RangeSource`、空间与位置报告、中文/JSON CLI，独立异步 JS 范围源、背压与取消，以及单文件 Blob/WAL 页面导航。

当前版本为 **v0.7.0**，从 v0.5.0 直接升级：包含同步 64 位范围读取、独立异步 JS 适配包、无 I/O 核心游标与 Blob/WAL 浏览器分块检查。v0.6.0 仅作为内部开发里程碑，未单独发布。契约及迁移方法见[范围读取](docs/range-source.md)、[异步范围读取](docs/async-source.md)和[v0.7.0 升级说明](docs/migration-0.7.md)。

## 安装

使用 MoonBit release 工具链，在现有项目中运行：

```sh
moon add prowk/moonsqlitefile@0.7.0
```

在消费包的 `moon.pkg` 中添加导入：

```moonbit
import {
  "prowk/moonsqlitefile" @sqlite,
}
```

## 快速上手

宿主读取数据库文件后，将完整字节传入 `open_database`。以下示例读取普通 rowid 表的前 10 行：

```moonbit
fn read_rows(data : Bytes) -> Array[@sqlite.Row] raise @sqlite.SqliteError {
  let db = @sqlite.open_database(data)
  db.table_rows("samples", limit=10)
}
```

`Row` 提供 `rowid`、`values` 和所在 `page_number`。值类型包括 `Null`、`Integer(Int64)`、`Real(Double)`、`Text(String)` 和 `Blob(Bytes)`。

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

`inspect_wal` 提供帧/提交报告；`WalSource::new` 可包装第三方同步源，再用 `open_wal_source` 打开。默认拒绝异常尾部，显式 `UseValidPrefix` 才读取异常前的完整提交；帧预算不足不能当作最新快照成功。输入必须是同一时刻的一致静态副本，详见 [WAL 契约](docs/wal.md)和[升级说明](docs/migration-0.5.md)。

## 命令行工具

CLI 需要 MoonBit release 工具链和 Node.js 22 或更新版本，无 npm 依赖：

```sh
git clone https://github.com/prowk/MoonSQLiteFile.git
cd MoonSQLiteFile
moon build --target js cmd/inspect
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

## 离线页面导航

当前源码先执行 `moon build --target js --deny-warn` 和 `python tools/build_viewer.py`，生成 `_build/moonsqlitefile-viewer.html`。界面支持静态 db/WAL、对象/父子/overflow 页导航、空间分布、cell 和原始字节；File/Blob 交给 Worker 按需分块读取，取消或预算耗尽显示部分结果。默认累计 payload 64 MiB、检查时间 120 秒，预算可调整，文件长度不再限制为 64 MiB。单文件没有外部资源，真实 Chrome 验收已覆盖本机页面载入后断网；直接 file:// 打开按本次交付范围保留为未验收项。详见[离线示例](examples/offline-viewer/README.md)。

[v0.7.0 Release](https://github.com/prowk/MoonSQLiteFile/releases/tag/v0.7.0) 提供可下载的单文件 HTML 和异步 JS 包 tarball。HTML 可通过本机静态 HTTP 服务载入后断网使用；直接 file:// 打开尚未验收。

独立异步包尚未发布 npm；下载 Release 中的 `prowk-moonsqlitefile-async-0.7.0.tgz` 后可执行 `npm install ./prowk-moonsqlitefile-async-0.7.0.tgz`，也可本地执行 `python tools/build_async.py`，使用 `_build/async-adapter`。它提供 Node 22 与 Blob 源、异步迭代器/visitor 背压、取消和详细检查，运行时没有第三方依赖，使用方式见[适配契约](docs/async-source.md)。

## 支持范围与限制

v0.4.0 补齐所访问 B-tree 页的空间覆盖与碎片计数校验，提供单页统计、详细树/全局诊断位置、对象占页汇总与离线导航。使用 `inspect_page`、`inspect_btree_details`、`inspect_database_details` 或 `DatabaseInspection.summarize()`。页面验证比 v0.3.0 更严格，升级前请阅读[升级说明](docs/migration-0.4.md)。

MoonSQLiteFile 返回**磁盘存储值**，字段保留磁盘顺序，不推断 SQL 列名、默认值或类型亲和性。普通表的 INTEGER PRIMARY KEY 字段通常存为 `Null`，其真实值位于 `Row.rowid`；WITHOUT ROWID 表按主键优先存储字段，索引记录可能附带 rowid 或主键字段。

当前版本只读静态数据库文件及最新已提交 WAL 覆盖快照，不执行 SQL、不写数据库、不执行 checkpoint、不获取在线并发快照，也不读取 shm 或提供任意历史事务。尚未验证索引排序与 collation、表与索引记录的一致性，也不提供 SQL 列映射；旧同步 `PageSource` 使用 `Int` 偏移；v0.7.0 合入原 v0.6.0 里程碑的 `RangeSource`、`CachedSource` 和 `RangeWalSource`，支持 64 位长度/偏移与 db/WAL 按需读取，页号最多为 2147483647。v0.7.0 在独立 JS 包提供异步 I/O；全局报告及 WAL 索引仍须独立预算，见[范围读取契约](docs/range-source.md)及[异步契约](docs/async-source.md)。

扫描或检查结果为 `Complete` 只表示其覆盖范围内的工作完成，不等同于 SQLite `integrity_check`。解析错误通过 `SqliteError` 返回，分为 `Invalid`、`Unsupported` 和 `LimitExceeded`；检查 API 将错误保留在报告中。

## 开发与测试

检出源码后，运行纯库示例：

```sh
moon run --target js examples/basic
```

预期输出：

```text
page_size=512, pages=1
schema entries=0
```

完整验证需要 MoonBit release、Node 22、Python 3.13；SQLite 引擎仅用于样本生成和结果对照。真实浏览器测试先按 CI 安装 Playwright 1.62.1 和 Chromium，或用 `MOONSQLITE_PLAYWRIGHT` / `MOONSQLITE_BROWSER` 指向已有包和浏览器。浏览器脚本使用本机临时 HTTP，载入后断网；不将其记为 file:// 验收：

```sh
moon check --target all --deny-warn
moon build --target all --deny-warn
moon test --target all --deny-warn
moon fmt --check
python tools/verify_api.py
python tools/generate_fixtures.py --check
python tools/verify_oracle.py
python tools/generate_btree_fixtures.py --check
python tools/verify_btree_oracle.py
python tools/verify_inspection.py
python tools/verify_wal_oracle.py
python tools/verify_review.py
node tools/verify_range_io.cjs
node tools/verify_wide_wal.cjs
python tools/verify_large_payload.py
python tools/benchmark_io.py
moon run --target js examples/basic
python tools/verify_consumer.py
python tools/build_viewer.py
node tools/verify_viewer.cjs
python tools/build_async.py
node tools/verify_async.mjs
python tools/verify_async_package.py
python tools/verify_async_wal.py
python tools/generate_browser_fixtures.py
node tools/verify_browser.cjs
node tools/fuzz.cjs --seed 20261003 --iterations 512
```

v0.7.0 四后端各 121 项核心回归，v0.3.0 的 85 项、v0.4.0 的 123 项、v0.5.0 的 160 项和 v0.6.0 的 199 项公开声明继续兼容检查；发布包在外部消费目录四后端运行，独立异步包另外通过实际 npm tarball 消费。同步验收继续覆盖 54 组 SQLite SQL 操作、2 GiB 主文件/WAL 范围、超过 64 MiB 的预算、1063 行普通表、4407 条索引/WITHOUT ROWID 记录及 2412 页归属。异步验收比较六组数据库所有根页和详细报告，并核对 29 组 WAL 快照、5470 条恢复记录；真实浏览器覆盖选文件、WAL、Worker、导航、取消、切换、释放和大库预算。Linux CI 要求 dbstat，远程验证以该提交对应的 GitHub CI 为准，不沿用旧提交的结果。CI 运行 512 次主文件/WAL 混合变更，每日任务 5000 次，失败时保存配对输入。详见[异步验收](docs/async-source.md)、[模糊测试与重放](docs/fuzzing.md)、[WAL 对照](docs/wal.md)及[样本说明](fixtures/README.md)。

问题反馈或改进建议请提交到 [GitHub Issues](https://github.com/prowk/MoonSQLiteFile/issues)。报告解析问题时，请附上复现步骤、错误输出及可公开的最小数据库样本。

## 许可证

采用 [Apache-2.0](https://github.com/prowk/MoonSQLiteFile/blob/main/LICENSE) 许可证。实现依据 [SQLite 官方磁盘格式规范](https://sqlite.org/fileformat.html)，未移植第三方解析器；详见 [来源说明](https://github.com/prowk/MoonSQLiteFile/blob/main/docs/provenance.md)。
