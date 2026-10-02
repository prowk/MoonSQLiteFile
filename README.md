# MoonSQLiteFile

[![CI](https://github.com/prowk/MoonSQLiteFile/actions/workflows/ci.yml/badge.svg)](https://github.com/prowk/MoonSQLiteFile/actions/workflows/ci.yml)

纯 MoonBit 的 SQLite 3 数据库文件解析与检查库：直接解释磁盘格式，提供页面、记录和 schema API。适用于文件格式教学、离线数据库检查、跨后端的数据库结构浏览器。

核心库只依赖 MoonBit 标准库，支持 Wasm、WasmGC、JS 与 native；Node CLI 宿主层只处理文件与进程 I/O。SQLite 引擎仅用于生成测试样本和对照结果。

## 已实现

- 100 字节文件头验证、512–65536 字节页面、安全页访问。
- 四类 B-tree 页头、cell pointer 与 freeblock 链检查。
- 1–9 字节 varint、全部标准 serial types、64 位整数、浮点、NULL、BLOB。
- UTF-8、UTF-16LE、UTF-16BE 严格解码。
- 普通 rowid 表的多层 B-tree 遍历、父键范围与循环检查。
- 索引及 WITHOUT ROWID 原始记录遍历，包含索引内部页记录，保留磁盘字段顺序。
- 逐条回调扫描、明确完成状态、累计 payload 与总页数预算。
- overflow 重组、sqlite_schema、表名解析与 freelist 检查。
- JSON CLI、真实 SQLite 对照测试与 GitHub Actions CI。

项目只读，不执行 SQL、不写数据库、不合并 WAL。索引记录的排序语义验证、SQL 列映射和全局页归属诊断尚未实现。输入应为安全获取的静态数据库副本；完整范围见 [架构说明](docs/architecture.md)。

## 获取与运行

要求 MoonBit release 工具链（本地验证 moon 0.1.20260920）、Node.js 22 或更新版本；对照验证还需要 Python 3.13。无 npm 依赖。

```sh
git clone https://github.com/prowk/MoonSQLiteFile.git
cd MoonSQLiteFile
moon build --target js cmd/inspect
node tools/inspect.cjs fixtures/core.sqlite header
node tools/inspect.cjs fixtures/core.sqlite schema
node tools/inspect.cjs fixtures/core.sqlite page 3
node tools/inspect.cjs fixtures/core.sqlite rows samples
node tools/inspect.cjs fixtures/core.sqlite rows branches 5
node tools/inspect.cjs fixtures/core.sqlite freelist
node tools/inspect.cjs fixtures/btree.sqlite records keyed 5
node tools/inspect.cjs fixtures/btree.sqlite index mixed_index 5
node tools/inspect.cjs fixtures/btree.sqlite scan 49 10
```

成功时 stdout 输出一行 JSON；失败时 stderr 输出错误，退出码非零。`rows` 默认最多 100000 行，传 `0` 返回空数组。整数和 rowid 用十进制字符串、BLOB 用十六进制，避免 JS 丢失 64 位精度。

`samples` 第一行 rowid 为 `"-7"`，中文字段为 `"中文 SQLite 🌙"`；`branches` 共 680 行；freelist 共 7 页。样本可重复生成，见 [fixtures 文档](fixtures/README.md)。

## 库 API

Mooncakes 发布尚未执行。当前从源码构建；发布后模块名为 `prowk/moonsqlitefile`。消费包的 `moon.pkg` 导入：

```moonbit
import {
  "prowk/moonsqlitefile" @sqlite,
}
```

宿主提供文件字节，库接收 `Bytes`：

```moonbit
fn inspect(data : Bytes) -> Array[@sqlite.Row] raise @sqlite.SqliteError {
  let db = @sqlite.open_database(data)
  db.table_rows("samples", limit=10)
}
```

运行纯库示例：

```sh
moon run --target js examples/basic
```

输出 `page_size=512, pages=1` 与 `schema entries=0`。API 见 [pkg.generated.mbti](pkg.generated.mbti) 和 [架构说明](docs/architecture.md)。

`Row.values` 是磁盘存储值，保持字段顺序：INTEGER PRIMARY KEY 通常为 `Null`，真实值位于 `Row.rowid`；REAL affinity 的值也可能存为 Integer。库不推断列名、主键别名或 SQL 默认值。

## 验证

```sh
moon check --target all --deny-warn
moon build --target all --deny-warn
moon test --target all --deny-warn
moon fmt --check
python tools/generate_fixtures.py --check
python tools/verify_oracle.py
```

测试覆盖四后端、真实 SQLite 查询、Unicode、overflow、损坏引用与资源预算。原始表读取验证 1063 行；索引及 WITHOUT ROWID 在三种页大小和文本编码中验证 4407 条记录，检查内部页记录的完整性和磁盘位置。CI 还验证实际发布包可由独立项目消费。Python 不参与核心运行时。

## 赛事与来源

依据 [SQLite 官方磁盘格式规范](https://sqlite.org/fileformat.html) 独立实现，未移植第三方解析器。已有 SQLite binding 用于执行 SQL，本项目直接检查文件结构，差异及十月规则来源见 [赛事工程记录](docs/competition.md)。

开发由 Codex AI 辅助，参赛者需理解并维护成果；正式一页申报书须人工撰写。目前工程准备不代表已报名或验收通过，后续还需 Mooncakes 发布、人工申报与报名材料提交。

Apache-2.0 许可证，见 [LICENSE](LICENSE) 与 [来源说明](docs/provenance.md)。
