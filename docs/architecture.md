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
| `Database.schema()/table_rows(name, limit?)` | schema 发现与按名称读取表 |
| `Database.freelist()` | 校验并列出 trunk/leaf 空闲页 |

失败通过 `SqliteError` 返回：`Invalid` 表示格式损坏、输入错误或越界，`Unsupported` 表示明确不支持的格式，`LimitExceeded` 表示资源请求超过限制。库不退出进程。

## 存储值与 SQL 逻辑值

`Row.values` 保留磁盘字段顺序与存储类型。`INTEGER PRIMARY KEY` 的字段通常是 `Null`，其真实值位于 `Row.rowid`；声明为 REAL 的值可能以整数存储。库不解析 CREATE TABLE 来恢复列名、类型亲和性、默认值或主键别名。调用者需要这些 SQL 语义时应使用 SQL 引擎或自行实现 schema 层。

## 安全与资源边界

默认最多读取 100000 行、单个 payload 16 MiB、每次遍历 100000 页、B-tree 深度 64。调用者可用 `Limits` 调整；`limit=0` 返回空行集合，小于资源上限的显式 limit 返回前缀，到达默认上限且仍有数据则抛出异常。限制约束读取工作量；文件字节和所有返回结果仍保存在内存，单次完整读表的总内存不是固定上限。

范围检查覆盖记录、cell pointer、保留空间、overflow 链和 freelist；B-tree 校验 rowid 顺序及父键上下界，拒绝子页重复/环。页面检查验证空闲块有序且不重叠。检查器不是 SQLite `integrity_check` 的替代品：尚不追踪整个数据库的页所有权，也不检查索引与表的一致性或每个 cell 的完整空间覆盖。

## 首版范围

- 支持 SQLite 3 普通 rowid 表、多层 table B-tree、schema、overflow、freelist、UTF-8/UTF-16LE/UTF-16BE、512–65536 字节页。
- 四种 B-tree 类型均可检查页面头；索引与 WITHOUT ROWID 的记录遍历暂未实现，读取此类表会返回 Unsupported。
- 不执行 SQL、不写入数据库、不合并 WAL、不处理 hot rollback journal、不恢复删除记录、不解密文件。
- 输入须为未被其他进程写入的完整数据库副本。WAL 模式应先在 SQLite 中 checkpoint 并安全复制或使用备份 API 获取快照；只读取 `.db` 无法看到未 checkpoint 的事务。文件头允许 WAL 版本号不代表实现了 WAL。

## 后续方向

索引键与 WITHOUT ROWID 遍历、页所有权分析、WAL 帧检查与一致快照合并、流式分页器、损坏数据库取证。首版不将这些方向标成已实现。
