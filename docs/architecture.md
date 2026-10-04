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

v0.4.0 补齐页内空间覆盖：四类 cell 的 varint、子页指针、页内 payload、overflow 指针和最小四字节填充均计入完整区间；与 freeblock 区间一起按物理偏移排序，拒绝重叠和碎片计数不一致。v0.6.0 改为累计全部未覆盖字节后比较碎片总数，兼容 SQLite 正常生成的较长间隙；仍拒绝未登记且不计入碎片的空间。freeblock 链必须递增且相隔至少四字节。校验只检查当前页，不读取 overflow 链或分配完整 payload；每页额外空间与区间数量成正比，排序后线性核对覆盖。

`Database.page` 和扫描都会先验证所访问页面的全部 cell 空间，因此 limit 读取前缀也可能因同页其他 cell 的空间损坏而失败；失败页上的记录尚未交给 callback，不计入已解码进度。这些检查从 v0.4.0 起生效；原有公开 API 与旧命令 JSON 结构未增加字段，行为变化见[升级说明](migration-0.4.md)。

## 页分类、对象占页和可读摘要（v0.4.0）

`DatabaseInspection.summarize()` 是对已有报告的纯汇总，返回 `InspectionSummary`，不会读取源或修改原报告。`claimed_pages`/`unclaimed_pages` 对应原报告的两个页列表；`page_kinds` 按固定顺序保留八种用途（包括零计数），`objects` 按根页和名称排序，统计每个已观察对象的 B-tree 与 overflow 页。对象列表包含 sqlite_schema，不包含 freelist、Ptrmap、lock-byte 或尚未认领的页；发生冲突时同一页只计入首次认领对象。

汇总不重新判断状态。调用者必须同时保留原报告的 status、ownership_complete、ptrmap_checked 与 diagnostics_truncated；失败或未完成时计数仅表示已观察到的归属，无法完整发现的对象可能不在列表中。全局页预算预检失败时两个页列表可能都为空，此时零计数不表示数据库没有页面。已认领页也可能在后续校验中失败，汇总不宣称它们全部有效。

CLI `summary-json` 提供精简 JSON：逻辑页数、页大小、覆盖标记、记录进度、原报告累计 payload 请求量、诊断数量、页分类及对象页数。对象的 `storage_bytes` 是 `(btree_pages + overflow_pages) × page_size`，用 UInt64 计算并输出十进制字符串；它包含 cell 元数据、页头和页内空闲空间，不是有效 payload。单页 payload 与空间利用率仍使用 inspect_page。未完成检查中已请求 payload 可能包括失败的解码请求，不推断每对象的有效数据大小。

CLI `summary` 提供中文文本摘要，显示上述范围、占页与带位置的诊断；名称中的换行等以 JSON 转义显示。summary 是文本输出，其他命令仍为 JSON。两个摘要命令沿用检查报告的 0/1/2 退出码；完整仅表示当前结构检查范围完成。参数与数据库初始化失败写 stderr。SQLite dbstat 可用时测试额外独立核对每对象 B-tree 与 overflow 占页。

## 树与全局诊断位置（v0.4.0）

`inspect_btree_details` 返回 `BTreeInspectionDetails`，包裹原有 `BTreeInspection` 并增加可选 `location`；`inspect_database_details` 返回 `DatabaseInspectionDetails`，包裹原有 `DatabaseInspection` 并提供同序同长度的 `LocatedDatabaseIssue` 列表。所有上下文来自执行检查的同一次扫描，不在失败后重读页面，也不解析错误字符串。原有公开类型与命令的输出结构保持原有形式。

`DiagnosticLocation.phase` 标识检查阶段，`page_number` 是该阶段实际读取或检查的页面；`byte_offset` 从页起点计数，`cell_index` 从零计数。页布局失败额外保留 `PageDiagnostic`；record/schema 解码错误指向所属 cell 起点，不承诺解码 payload 内部或跨页字段的精确地址。overflow 链错误指向保存链接的源页字段，目标页读取失败则指向尝试读取的页且无页内偏移。Ptrmap 格式与对照失败指向 map 页的条目或父页字段。不能确定位置时保留 None，资源与 schema 元数据错误不沿用上一页的位置。

位置快照与诊断一起保存；达到 max_issues 后两者一起截断，状态与进度均保留原有检查契约。未出现错误的 RecordLimit 前缀返回 Incomplete 和空 location。详细树及全局报告使用现有检查状态：宿主抛出 Invalid 仍可能表现为 Failed，但 ReadPage 阶段明确表示该页未能取得，调用者不能据此宣称数据库格式损坏。这与单页 inspect_page 对读取失败返回 Incomplete 的新契约不同。

CLI `tree-inspect ROOT [LIMIT]` 返回状态、成功解码记录数、完成原因、错误和位置；`inspect-details` 返回原有 `inspection` JSON 及与其 issues 逐项对应的 `locations` 数组。位置中的 `page_code` 是可选页布局分类，原始错误保留在相应报告中。两个命令均向 stdout 输出报告，退出码 0/1/2 分别表示 Complete/Failed/Incomplete；参数与初始化错误仍写 stderr。

## 页面检查与空间统计（v0.4.0）

`Database.inspect_page(number)` 新增独立的 `PageInspection`，复用 `Database.page` 与扫描器的页布局解析器。它只读取指定的一页，不遍历子页或 overflow，不解码 record，也不验证页归属。`Complete` 仅表示该页 B-tree 布局符合已实现的检查；它不证明整棵树、数据库或该页的外部链接有效。对 freelist 等非 B-tree 页调用此 API 会报告页类型失败，不表示该页在原有用途下损坏。

报告成功时提供 `page` 和 `statistics`，`diagnostic` 为 None；格式失败或超出表示范围时只提供诊断，不返回部分统计。`PageDiagnostic.code` 区分页类型、页头、cell 指针、cell 格式、freeblock、空间重叠、未登记空闲区间、碎片计数和右子页字段。`page_number` 是实际被检查的页，`byte_offset` 从页面起点计数，`cell_index` 从零计数；位置指向检查失败的字段或区间，cell 格式失败指向 cell 起点，不承诺每个 varint 内部字节的精确位置。保留原始 `SqliteError`，分类不依赖解析错误文本。

读取失败（包括页号越界、宿主抛出 Invalid 或短读）使用 `PageRead`、无偏移及 `Incomplete`，因为没有取得可检查的完整页；不能据此判定数据库损坏。已取得完整页后的 Invalid 为 Failed，Unsupported/LimitExceeded 为 Incomplete。该区分只适用于新接口，已有树/数据库检查报告的错误语义保持原有形式。

`PageStatistics` 的八个空间分项互不重叠，合计等于 page_size：文件头（仅第一页 100 字节）、B-tree 页头、cell pointer 数组、未分配区、完整 cell（含元数据/overflow 指针/最小填充）、freeblock、碎片和末尾保留区。`payload_bytes` 累计本页 cell 声明的完整 payload；`local_payload_bytes` 只累计页内 payload；`max_payload_bytes` 是最大单 cell 声明值，`overflow_cells` 是需要 overflow 的 cell 数。table interior 的 rowid 分隔键不计为 payload。声明值不意味着链已读取或内容已验证，且页报告无需分配完整 payload，因此不应用记录解码的 payload 内存限额；超出 Int 表示范围仍返回 LimitExceeded。

SQLite 的 [dbstat](https://sqlite.org/dbstat.html) 在 B-tree 页上的 ncell、payload、mx_payload 分别对应 cell_count、local_payload_bytes、max_payload_bytes；unused 对应未分配区、freeblock 和碎片的和。测试在 dbstat 可用时进行独立对照；未启用 dbstat 的环境仍检查字节分项及声明 payload 与完整扫描的总和。

CLI `page-inspect N` 返回上述报告；退出码为 0（Complete）、1（Failed）或 2（Incomplete）。报告写 stdout，参数或数据库初始化错误仍写 stderr。两个 UInt64 payload 累计字段序列化为十进制字符串，其他计数为 JSON 数字。原有 `page N` 输出保持原有结构。此次 API 演进仅新增类型、方法和命令，不给 SqliteError、DatabaseIssue 或现有公开结构添加分支/字段，保留已有消费代码的构造和穷举匹配。

## 当前范围

- 支持 SQLite 3 普通 rowid 表、多层 table B-tree、schema、overflow、freelist、UTF-8/UTF-16LE/UTF-16BE、512–65536 字节页。
- 四种 B-tree 均可遍历记录；索引采用左子树 → 内部 cell → 右子树顺序。WITHOUT ROWID 返回主键列在前的磁盘存储顺序，rowid 为 None。索引返回索引字段与附加 rowid/主键；附加值保留在 values 中，不单独推断。
- `read_table`/`table_rows` 保持 v0.1 的普通 rowid 表接口；WITHOUT ROWID 请使用 `table_records`。尚不解释 SQL 列映射、collation、DESC 排序或约束，不对这些语义宣称验证通过。
- 提供 WAL 帧校验和最新已提交只读覆盖源；默认拒绝无效尾部，显式前缀策略只采用此前完整提交。只读快照不写回主文件。
- 不执行 SQL、不写入数据库、不执行 checkpoint、不处理 hot rollback journal、不恢复删除记录、不解密文件。
- 输入须为未被其他进程写入的完整静态副本。WAL 模式可先 checkpoint/备份后读取主文件，或提供同一时刻的一致 db/WAL 副本并显式使用 WAL 入口；只读取 `.db` 无法看到未 checkpoint 的事务。salt/checksum 不验证主文件身份，在线锁协议仍由宿主提供。

## WAL 快照（v0.5.0）

`parse_wal_header` / `inspect_wal` 验证格式、两种 checksum 输入字节序、salt、连续有效范围和提交边界，保留首个停止原因。`WalSource` 实现 PageSource，反向线性索引最后提交前的页版本，忽略未提交帧；缩小边界淘汰旧的高页号版本，再次增长需要完整新页覆盖。`open_wal_source` 用提交页数初始化原有 Database；原始页 1 声明不覆盖逻辑边界。

接口、异常尾部、空 WAL 与一致副本责任详见 [WAL 契约](wal.md)。这里只读取最新已提交视图，不提供历史事务、在线锁、shm、checkpoint 或写事务。原有静态主文件 API、公开结构和 JSON 不增加字段。

## 后续方向

v0.5.0 已完成 WAL 帧检查与已提交快照覆盖；后续依次扩展 64 位与异步宿主读取、稳定版契约及有限恢复。索引排序与表/索引内容一致性属于独立的语义检查范围。
