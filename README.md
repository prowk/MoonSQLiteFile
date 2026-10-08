<div align="center">

# MoonSQLiteFile

[![CI](https://github.com/prowk/MoonSQLiteFile/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/prowk/MoonSQLiteFile/actions/workflows/ci.yml)
[![Mooncakes](https://img.shields.io/badge/Mooncakes-v0.8.0-2563eb)](https://mooncakes.io/docs/prowk/moonsqlitefile@0.8.0)
[![License](https://img.shields.io/badge/License-Apache--2.0-2563eb)](LICENSE)

**纯 MoonBit 的 SQLite 文件解析与检查库**

[API 文档](https://mooncakes.io/docs/prowk/moonsqlitefile@0.8.0) · [使用指南](docs/usage.md) · [下载工具](https://github.com/prowk/MoonSQLiteFile/releases/tag/v0.8.0)

</div>

直接读取 SQLite 3 磁盘格式，用于离线数据库浏览、结构检查和存储格式教学。
核心只依赖 MoonBit 标准库，支持 **Wasm、WasmGC、JavaScript 和 native**，无需 SQLite 引擎或 FFI；文件 I/O 由宿主提供。

## 能力

- **读取记录**：普通表、索引、WITHOUT ROWID、overflow，以及 UTF-8 / UTF-16 文本。
- **检查结构**：页面空间、B-tree、freelist、页归属及 Ptrmap，提供诊断位置与空间汇总。
- **读取 WAL**：校验帧和提交边界，读取一致静态 db/WAL 副本的最新已提交快照。
- **按需处理**：64 位范围源、有界缓存与资源预算；独立 JS 适配提供异步扫描、背压和取消。

## 安装

在 MoonBit 项目中运行：

```sh
moon add prowk/moonsqlitefile@0.8.0
```

在消费包的 `moon.pkg` 中导入：

```moonbit
import {
  "prowk/moonsqlitefile" @sqlite,
}
```

已发布安装版本为 v0.8.0；仓库源码 v0.8.2 尚未发布。工具链和宿主版本见[支持说明](docs/support.md)。

## 快速上手

由宿主读取静态数据库文件，将完整字节传入以下函数，读取 `samples` 表的前 10 行：

```moonbit
fn read_rows(data : Bytes) -> Array[@sqlite.Row] raise @sqlite.SqliteError {
  let db = @sqlite.open_database(data)
  db.table_rows("samples", limit=10)
}
```

`Row` 包含 `rowid`、`values` 和所在 `page_number`。返回的是**磁盘存储值**，不自动还原 SQL 列名、默认值或类型亲和性；INTEGER PRIMARY KEY 的实际值应读取 `rowid`。

上述表可用仓库中的 `fixtures/core.sqlite` 复现。索引、逐条扫描、检查报告与 WAL 示例见[使用指南](docs/usage.md)；大文件请使用[范围源](docs/range-source.md)，避免先读入完整文件。

## 工具入口

- **Node.js CLI**：克隆仓库后按下方命令检查样本；[完整命令与输出约定](docs/usage.md#命令行工具)
- **浏览器查看器**：从 [v0.8.0 Release](https://github.com/prowk/MoonSQLiteFile/releases/tag/v0.8.0) 下载单文件 HTML；[使用说明](examples/offline-viewer/README.md)
- **异步 JS 包**：从同一 Release 下载 tarball；[安装、扫描与取消](docs/async-source.md)。尚未发布 npm registry

在仓库根目录运行：

```sh
moon build --target js src/cmd/inspect
node tools/inspect.cjs fixtures/core.sqlite summary
```

## 使用边界

- 只读使用期间不变的静态副本；db/WAL 必须来自同一时刻。不执行 SQL、写入、checkpoint 或在线快照获取。
- 检查 `Complete` 仅表示声明范围内工作完成，不等同于 SQLite `integrity_check`；不验证索引排序/collation 或表与索引内容一致性。
- 缓存、页数、记录和 payload 各有预算；大文件寻址不等于常量内存，预算耗尽时须处理未完成状态。

浏览器启动方式与完整限制见[支持说明](docs/support.md#浏览器启动方式)。

## 文档与贡献

- **常用 API 与 CLI**：[使用指南](docs/usage.md)、[Mooncakes API](https://mooncakes.io/docs/prowk/moonsqlitefile@0.8.0)
- **数据源、异步与 WAL**：[范围读取](docs/range-source.md)、[异步适配](docs/async-source.md)、[WAL 契约](docs/wal.md)
- **实现与支持范围**：[架构](docs/architecture.md)、[支持矩阵](docs/support.md)
- **开发与验证**：[贡献指南](CONTRIBUTING.md)、[性能基准](docs/io-benchmark.md)
- **升级与历史变化**：[按版本升级说明](docs/migration.md)、[CHANGELOG](CHANGELOG.md)

问题反馈请提交到 [GitHub Issues](https://github.com/prowk/MoonSQLiteFile/issues)，附复现步骤、错误输出及可公开的最小数据库样本。

## 许可证

[Apache-2.0](LICENSE)。依据 [SQLite 官方磁盘格式](https://sqlite.org/fileformat.html) 实现；第三方来源与实现边界见[来源说明](docs/provenance.md)。
