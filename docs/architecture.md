# 架构与边界

## 数据流

`Bytes → parse_header → Database → page → read_table → cell_payload → decode_record → schema/table_rows`

库只导入 MoonBit 标准库。所有数值、varint、B-tree、Unicode、overflow 和 freelist 解析均由 MoonBit 完成；Node launcher 仅读取字节、提供进程参数和转发输出。Python sqlite3 只用于测试数据与独立对照验证。

## API

| API | 用途 |
| --- | --- |
| `parse_header(Bytes)` | 验证并读取 100 字节数据库头 |
| `decode_varint(Bytes, offset)` | 解码 1–9 字节 SQLite varint，返回 UInt64 与消耗字节数 |
| `decode_record(Bytes, encoding)` | 原始记录解码，支持所有标准 serial types |
| `open_database(Bytes, limits?)` | 打开完整、只读的内存快照 |
| `Database.header()/page_count()` | 元数据与逻辑页数 |
| `Database.read_page(number)/page(number)` | 原始页或四种 B-tree 页元数据 |
| `Database.read_table(root, limit?)` | 按 rowid 遍历普通表 |
| `Database.read_btree(root, limit?, max_total_payload_bytes?)` | 四种 B-tree 的原始记录 |
| `Database.read_index(root, limit?)` | 原始索引记录，包含内部 cell |
| `Database.scan_btree(root, visit, limit?, max_total_payload_bytes?)` | 逐条回调并返回扫描完成状态 |
| `Database.table_records(name)/index_records(name)` | 按名称读取普通表、WITHOUT ROWID 或索引的原始记录 |
| `Database.schema()/table_rows(name, limit?)` | schema 发现与按名称读取表 |
| `Database.freelist()` | 校验并列出 trunk/leaf 空闲页 |

失败通过 `SqliteError` 返回：`Invalid` 表示格式损坏、输入错误或越界，`Unsupported` 表示明确不支持的格式，`LimitExceeded` 表示资源请求超过限制。库不退出进程。

## 存储值与 SQL 逻辑值

`Row.values` 保留磁盘字段顺序与存储类型。`INTEGER PRIMARY KEY` 的字段通常是 `Null`，其真实值位于 `Row.rowid`；声明为 REAL 的值可能以整数存储。库不解析 CREATE TABLE 来恢复列名、类型亲和性、默认值或主键别名。调用者需要这些 SQL 语义时应使用 SQL 引擎或自行实现 schema 层。

## 安全与资源边界

默认最多读取 100000 条记录、单个 payload 16 MiB、累计 payload 64 MiB、每次遍历 100000 页、B-tree 深度 64。调用者可用 `Limits` 与 `max_total_payload_bytes` 调整。页预算在同一棵树内共享，包含 overflow，并拒绝多个 cell 共用 overflow 或与 B-tree 页冲突。

`scan_btree` 的 callback 返回 true 继续、false 停止。`ScanSummary.completion` 区分 Complete、RecordLimit 和 VisitorStopped，准确到达行数上限且无剩余记录仍返回 Complete。回调无需由库保存整表，但调用者保留记录仍会占用内存。单条 payload 仍先完整解码；累计预算不等价于精确堆内存上限。

集合读取的显式小 limit 返回前缀，默认资源上限导致未完成则抛出异常。读取完成只说明遍历结束，不代表执行了 SQLite integrity_check 或索引排序语义验证。

范围检查覆盖记录、cell pointer、保留空间、overflow 链和 freelist；B-tree 校验 rowid 顺序及父键上下界，拒绝子页重复/环。页面检查验证空闲块有序且不重叠。检查器不是 SQLite `integrity_check` 的替代品：尚不追踪整个数据库的页所有权，也不检查索引与表的一致性或每个 cell 的完整空间覆盖。

## 首版范围

- 支持 SQLite 3 普通 rowid 表、多层 table B-tree、schema、overflow、freelist、UTF-8/UTF-16LE/UTF-16BE、512–65536 字节页。
- 四种 B-tree 均可遍历记录；索引采用左子树 → 内部 cell → 右子树顺序。WITHOUT ROWID 返回主键列在前的磁盘存储顺序，rowid 为 None。索引返回索引字段与附加 rowid/主键；附加值保留在 values 中，不单独推断。
- `read_table`/`table_rows` 保持 v0.1 的普通 rowid 表接口；WITHOUT ROWID 请使用 `table_records`。尚不解释 SQL 列映射、collation、DESC 排序或约束，不对这些语义宣称验证通过。
- 不执行 SQL、不写入数据库、不合并 WAL、不处理 hot rollback journal、不恢复删除记录、不解密文件。
- 输入须为未被其他进程写入的完整数据库副本。WAL 模式应先在 SQLite 中 checkpoint 并安全复制或使用备份 API 获取快照；只读取 `.db` 无法看到未 checkpoint 的事务。文件头允许 WAL 版本号不代表实现了 WAL。

## 后续方向

索引键与 WITHOUT ROWID 遍历、页所有权分析、WAL 帧检查与一致快照合并、流式分页器、损坏数据库取证。首版不将这些方向标成已实现。
