# 架构与边界

## 数据流

`Bytes → parse_header → Database → page → read_table → cell_payload → decode_record → schema/table_rows`

v0.2 将输入抽象为 `PageSource → Database → 统一 B-tree walker → 原始记录回调/集合接口`。`BytesSource` 包装原有内存字节；`open_source` 只读取 100 字节头，后续按页面边界请求字节。PageSource 是同步接口，使用 Int 偏移和长度，不支持超过当前 Int 地址范围的文件，也不包含锁、异步 I/O 或快照获取协议。自定义源必须保持内容不变，范围读取必须完整返回请求字节，宿主错误统一通过 SqliteError 传播。

库只导入 MoonBit 标准库。所有数值、varint、B-tree、Unicode、overflow 和 freelist 解析均由 MoonBit 完成；Node launcher 仅读取字节、提供进程参数和转发输出。Python sqlite3 只用于测试数据与独立对照验证。

## API

| API | 用途 |
| --- | --- |
| `parse_header(Bytes)` | 验证并读取 100 字节数据库头 |
| `decode_varint(Bytes, offset)` | 解码 1–9 字节 SQLite varint，返回 UInt64 与消耗字节数 |
| `decode_record(Bytes, encoding)` | 原始记录解码，支持所有标准 serial types |
| `open_database(Bytes, limits?)` | 打开完整、只读的内存快照 |
| `BytesSource.new(Bytes)/open_source(&PageSource, limits?)` | 打开宿主提供的只读静态数据源 |
| `Database.header()/page_count()` | 元数据与逻辑页数 |
| `Database.read_page(number)/page(number)` | 原始页或四种 B-tree 页元数据 |
| `Database.read_table(root, limit?)` | 按 rowid 遍历普通表 |
| `Database.read_btree(root, limit?, max_total_payload_bytes?)` | 四种 B-tree 的原始记录 |
| `Database.read_index(root, limit?)` | 原始索引记录，包含内部 cell |
| `Database.scan_btree(root, visit, limit?, max_total_payload_bytes?)` | 逐条回调并返回扫描完成状态 |
| `Database.table_records(name)/index_records(name)` | 按名称读取普通表、WITHOUT ROWID 或索引的原始记录 |
| `Database.schema()/table_rows(name, limit?)` | schema 发现与按名称读取表 |
| `Database.freelist()` | 校验并列出 trunk/leaf 空闲页 |
| `Database.inspect_btree(root, limit?, max_total_payload_bytes?)` | 单树检查状态、进度与原始错误 |
| `Database.inspect_database(max_total_payload_bytes?, max_issues?)` | 全局页归属、冲突、未知页与 Ptrmap 诊断 |
| `Database.ptrmap_entries()` | 读取 auto-vacuum 反向指针条目 |

失败通过 `SqliteError` 返回：`Invalid` 表示格式损坏、输入错误或越界，`Unsupported` 表示明确不支持的格式，`LimitExceeded` 表示资源请求超过限制。库不退出进程。

## 单棵树检查报告

`Database.inspect_btree(root, limit?, max_total_payload_bytes?)` 复用有界扫描，不收集记录数组，并把 SqliteError 转换为 `BTreeInspection`。报告包含调用者指定的 `root_page`、`status`、成功解码的 `records_decoded`、可选 `summary` 和可选 `error`。

- `Complete`：遍历结束，`summary` 保留完整 ScanSummary，`error` 为 None。
- `Incomplete`：达到记录上限时，`summary.completion` 为 RecordLimit；资源限制或 Unsupported 错误时，`error` 保留原始错误，`summary` 为 None。
- `Failed`：发生 Invalid 错误，`error` 保留原始错误，`summary` 为 None。Invalid 也可能来自无效根页或宿主读取失败，不能据此直接断定数据库损坏。

发生错误时，仍保留此前交给内部回调的已解码记录数，不推测失败路径中的页数、payload 总量或错误位置。报告里的根页号是检查入口，不是错误发生页。初始化失败仍由 `open_database` 或 `open_source` 抛出，不属于这个报告的覆盖范围。

这个接口只报告单棵 B-tree 的现有检查结果；不扫描全局页归属、Ptrmap、表与索引一致性，也不等价于 SQLite integrity_check。

## 全局页归属

`Database.inspect_database(max_total_payload_bytes?, max_issues?)` 扫描 sqlite_schema、其中所有独立表和索引根页，以及 freelist。页报告按逻辑页号排序，包含 PageKind、所属对象、根页和父页；schema 也计入总记录数。已认领页被其他树或 freelist 再次引用时，PageConflict 保存两次归属；每棵树内部的环与重复引用仍由原扫描器拒绝。

全程共享 Limits 的记录和页数上限、累计 payload 预算及默认 100 条诊断上限。payload 在分配和解码前扣减，失败的请求也不退还预算；它不是精确堆内存统计。逻辑页数超出页预算时提前返回，避免枚举无界页列表。报告不扫描声明逻辑页数之外的物理尾部。

ownership_complete 表示 schema 根页发现和归属遍历已完成，不等价于数据库完整性；仅在该标记为 true 时，未认领的逻辑页才产生 UnclaimedPage 错误。未完整扫描时，同样的页列表只是待解释页。失败保留已认领页及已有诊断，diagnostics_truncated 明示诊断截断。

auto-vacuum 下按可用页尺寸保留 Ptrmap 页，并保留 lock-byte 页；Ptrmap 恰好落在 lock-byte 页时后移一页。校验五类条目与零父页/有效父页规则，并与扫描取得的根页、子页、首个 overflow、后续 overflow 和 freelist 归属交叉对照；同时检查 largest root 与根页排列。PtrmapMismatch 同时保留实际条目和预期归属，不从反向指针推断未知页的用途。

ptrmap_checked 为 true 表示所有适用条目均已对照；即使发现不一致，该标记仍可为 true，此时 status 为 Failed。归属不完整、条目无法解析或诊断达到上限导致提前停止时为 false。没有 Ptrmap 的数据库该标记为 true，表示不适用。单独调用 ptrmap_entries 返回原始条目并执行格式检查，不验证真实归属。虚拟表的零根页定义不占页面，shadow 表仍独立扫描。尚未检查 SQL 排序、列语义及表/索引记录一致性。

CLI `inspect` 返回 JSON 报告；退出码 0 为 Complete、1 为 Failed、2 为 Incomplete。能够构造报告时诊断位于 stdout；参数或初始化错误仍写 stderr。

## 存储值与 SQL 逻辑值

`Row.values` 保留磁盘字段顺序与存储类型。`INTEGER PRIMARY KEY` 的字段通常是 `Null`，其真实值位于 `Row.rowid`；声明为 REAL 的值可能以整数存储。库不解析 CREATE TABLE 来恢复列名、类型亲和性、默认值或主键别名。调用者需要这些 SQL 语义时应使用 SQL 引擎或自行实现 schema 层。

## 安全与资源边界

默认最多读取 100000 条记录、单个 payload 16 MiB、累计 payload 64 MiB、每次遍历 100000 页、B-tree 深度 64。调用者可用 `Limits` 与 `max_total_payload_bytes` 调整。页预算在同一棵树内共享，包含 overflow，并拒绝多个 cell 共用 overflow 或与 B-tree 页冲突。

`scan_btree` 的 callback 返回 true 继续、false 停止。`ScanSummary.completion` 区分 Complete、RecordLimit 和 VisitorStopped，准确到达行数上限且无剩余记录仍返回 Complete。回调无需由库保存整表，但调用者保留记录仍会占用内存。单条 payload 仍先完整解码；累计预算不等价于精确堆内存上限。

集合读取的显式小 limit 返回前缀，默认资源上限导致未完成则抛出异常。读取完成只说明遍历结束，不代表执行了 SQLite integrity_check 或索引排序语义验证。

范围检查覆盖记录、cell pointer、保留空间、overflow 链和 freelist；B-tree 校验 rowid 顺序及父键上下界，拒绝子页重复/环，空叶页也参与深度验证。全局检查追踪逻辑数据库的页归属与 Ptrmap；检查器不是 SQLite `integrity_check` 的替代品，尚不检查索引排序或索引与表的内容一致性。

开发中的 v0.4.0 补齐页内空间覆盖：四类 cell 的 varint、子页指针、页内 payload、overflow 指针和最小四字节填充均计入完整区间；与 freeblock 区间一起按物理偏移排序，拒绝重叠、未登记的四字节及以上空闲区间和碎片计数不一致。freeblock 链必须递增且相隔至少四字节。校验只检查当前页，不读取 overflow 链或分配完整 payload；每页额外空间与区间数量成正比，排序后线性核对覆盖。

`Database.page` 和扫描都会先验证所访问页面的全部 cell 空间，因此 limit 读取前缀也可能因同页其他 cell 的空间损坏而失败；失败页上的记录尚未交给 callback，不计入已解码进度。这些检查尚未包含在已发布的 v0.3.0 中；公开 API 与 JSON 结构未增加字段。

## 当前范围

- 支持 SQLite 3 普通 rowid 表、多层 table B-tree、schema、overflow、freelist、UTF-8/UTF-16LE/UTF-16BE、512–65536 字节页。
- 四种 B-tree 均可遍历记录；索引采用左子树 → 内部 cell → 右子树顺序。WITHOUT ROWID 返回主键列在前的磁盘存储顺序，rowid 为 None。索引返回索引字段与附加 rowid/主键；附加值保留在 values 中，不单独推断。
- `read_table`/`table_rows` 保持 v0.1 的普通 rowid 表接口；WITHOUT ROWID 请使用 `table_records`。尚不解释 SQL 列映射、collation、DESC 排序或约束，不对这些语义宣称验证通过。
- 不执行 SQL、不写入数据库、不合并 WAL、不处理 hot rollback journal、不恢复删除记录、不解密文件。
- 输入须为未被其他进程写入的完整数据库副本。WAL 模式应先在 SQLite 中 checkpoint 并安全复制或使用备份 API 获取快照；只读取 `.db` 无法看到未 checkpoint 的事务。文件头允许 WAL 版本号不代表实现了 WAL。

## 后续方向

接下来完善结构化诊断、页面统计与检查结果展示，再扩展 WAL 帧检查与一致快照读取、宿主分页器和有限恢复。索引排序与表/索引内容一致性属于独立的语义检查范围。
