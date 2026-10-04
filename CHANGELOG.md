# 更新记录

## 0.6.0（待发布）

修复 SQLite 正常产生的较长空闲间隙被误拒：累计页内未覆盖字节并核对 fragmented bytes，碎片不一致统一定位为 FragmentCount。

## 0.5.0

持续模糊测试扩展到 WAL：每四次变更中一次使用配对主文件与 WAL，覆盖双 checksum 字节序和未提交尾帧；部分变更重算 checksum，继续检查覆盖源及损坏页面。失败样本同时保存主文件并自动配对重放。修正模糊工具对 65536 页头编码 1 的实际页长定位。

CLI 新增 `--wal WAL [--wal-prefix]`，所有原有命令可读取覆盖快照；`wal-inspect` 检查独立 WAL，`wal-info` 展示帧、提交边界、停止原因与快照页数。新增真实 SQLite WAL 恢复对照，覆盖两种 checksum 字节序、三种文本编码、512/4096/65536 页、多事务、未提交尾部、中间损坏、reset 与缩小后增长；核实输入文件没有被改写。

新增 WAL header/frame 校验、两种累计 checksum 字节序、salt 和提交边界报告。`parse_wal_header` 与 `inspect_wal` 提供连续有效帧及首个停止原因，覆盖空 WAL、未提交帧、异常尾部与资源上限。

新增只读 `WalSource`、`open_wal_source` 和 `open_wal_database`，复用原有 Database 检查器读取最新已提交快照，采用提交后的逻辑页数；正确隔离未提交更新、缩小及重新增长后的旧页面版本。默认拒绝异常尾部，显式 `UseValidPrefix` 才使用此前完整提交；帧限额不足不能作为旧快照成功返回。宿主负责同一时刻的一致静态 db/WAL 副本，不提供在线锁或 checkpoint。详见 [WAL 契约](docs/wal.md)。

保持 v0.3.0 的 85 项和 v0.4.0 的 123 项公开声明兼容，检查器先重新生成当前接口以确认同步。独立消费项目覆盖第三方 PageSource、WAL header/frame 报告和已提交视图，并在四后端运行。四后端各 98 项回归通过，新增 29 组 WAL 快照、5470 条记录的 SQLite 恢复对照；原有 1063 行普通表、4407 条索引/WITHOUT ROWID 记录及 2412 页对照继续通过。新入口的严格尾部、逻辑页数及副本责任见 [v0.5.0 升级说明](docs/migration-0.5.md)。

## 0.4.0

新增可重放的持续模糊测试：CI 固定种子运行 512 次字节变更，每日任务运行 5000 次并更换种子；独立 Worker 限制堆与单输入时间，覆盖初始化、全局/树/页报告及资源约束，异常保存原始输入和重放元数据。此项为 JavaScript 后端的有界变更测试，不采用覆盖率引导；核心回归继续覆盖四后端。

新增页面导航与最小离线检查器：以单个 HTML 复用 MoonBit 报告，提供对象根页、父子页和 overflow 跳转、空间分布、cell 定位、原始字节和失败位置。CLI 增加 `viewer-data`，在同一次扫描中输出界面需要的详细报告与纯汇总。演示完整读取最多 64 MiB 的静态副本，Worker 超时为 30 秒，切换时取消旧任务；不包含网络资源，不支持 WAL。CI 验证实际打包 HTML 中的解析器、导航关系与受控损坏诊断。

新增 `DatabaseInspection.summarize`：对已经认领的页汇总八类用途，并按对象/根页统计 B-tree 与 overflow 页数，不重读数据库、不重复计入冲突引用。CLI 新增中文 `summary` 和精简 `summary-json`，显示覆盖状态、对象占页字节、已请求 payload 与诊断；未完成或截断检查明确保留部分结果。对象占页字节含页内空闲区，不作为有效 payload；freelist/Ptrmap/lock-byte 和未知页单独统计。

新增 `inspect_btree_details` 与 `inspect_database_details`，在同一次扫描中保存失败阶段、实际页号、页内字段/区间及可用的 cell 下标；覆盖页布局、树遍历、payload/overflow、record/schema 解码、freelist、页归属和 Ptrmap。详细报告包裹现有报告，保持原有状态语义、进度和诊断上限；已有错误枚举和报告结构保持原有形式。CLI 增加 `tree-inspect ROOT [LIMIT]` 和 `inspect-details`，现有命令的 JSON 格式保持不变。位置未知时返回空值，不从错误文本猜测位置；读取阶段失败不能直接推断为文件损坏。

修复空叶页跳过 B-tree 深度验证的问题；深度不一致的树现在返回 `Invalid`，检查报告为 `Failed`，并保留此前成功解码的记录数。

补齐四种 B-tree 页的 cell 空间覆盖校验，包含 varint、子页指针、页内 payload、overflow 指针及最小四字节填充；拒绝 cell 互相重叠、cell 与 freeblock 内容重叠、间距不足的 freeblock 链、未登记空闲区间和错误碎片计数。页面校验不读取 overflow 链、不分配完整 payload；公开 API 和 JSON 结构不变。行为收紧：`page` 及扫描现在验证所访问页面中全部 cell 的空间，显式 limit 读取前缀也可能因同页其他 cell 的空间损坏而失败。

新增真实 SQLite 删除与变长更新后的空间对照，覆盖四种 B-tree、512–65536 字节页与三种文本编码，并对碎片计数和未登记空闲区间进行受控损坏验证。

新增 `Database.inspect_page`、`PageInspection`、`PageStatistics` 与 `PageDiagnostic`：对指定 B-tree 页返回空间分项、声明的总/页内 payload、最大单 cell payload 和 overflow cell 数；格式失败保留分类、实际页号、页内偏移及可用时的 cell 下标。读取失败标记为 `Incomplete`，不从宿主 `Invalid` 推断数据库损坏。CLI 新增 `page-inspect N`，用 JSON 和退出码返回同一报告；已有错误枚举、报告类型和命令输出结构保持原有形式。空间与记录扫描复用同一解析过程，仅读取目标页，不验证 overflow 链、record 内容或整棵树。新增四后端回归、SQLite dbstat 页统计对照及独立消费验证。

公开 API 审查确认 v0.3.0 的 85 项声明保持源码兼容，新增报告采用独立类型。行为收紧及报告语义见[升级说明](docs/migration-0.4.md)。四后端各 86 项回归通过，SQLite 对照覆盖 1063 行普通表、4407 条索引/WITHOUT ROWID 记录及 18 个数据库 2412 页；另通过实际 HTML 和独立打包消费验证。

## 0.3.0

新增 `Database.inspect_database`、页用途与归属报告以及 `inspect` JSON CLI。统一发现 schema 根页、跟踪跨树 B-tree/overflow 引用、检查 freelist 冲突并枚举未认领页；全局共享记录、页数和累计 payload 预算。若发现根页不完整，未认领页仅作为未知列表，不判定为孤儿。CLI 退出码区分完整、失败和未完成，诊断保留在 JSON 报告中。

新增 `Database.ptrmap_entries`：支持 FULL / INCREMENTAL auto-vacuum 的五类反向指针，验证类型、父页、largest root 和根页排列，与真实 B-tree、overflow、freelist 归属交叉检查；处理保留空间与 lock-byte 页位移。`PtrmapMismatch` 保留实际条目与预期归属。报告分别标识归属遍历、Ptrmap 检查和诊断截断，避免将部分扫描误判为完整。

新增 `Database.inspect_btree` 和 `BTreeInspection`：对单棵 B-tree 返回完整、未完成或失败状态，保留原始 SqliteError 和此前成功解码的记录数。记录上限、资源不足或不支持的格式不会被当作完整检查；该报告不提供全局页归属或整个数据库的完整性结论。

四后端各 55 项测试通过。SQLite 页归属对照覆盖 13 个数据库、1765 页；受控损坏验证别名根页、孤儿页、Ptrmap 类型与父页错误以及诊断截断。独立消费验证覆盖新检查 API 和第三方 PageSource。结构检查仍不等价于 SQLite integrity_check：SQL 排序、表/索引记录一致性和完整 cell 空间覆盖不在本版本范围内。

## 0.2.0

统一普通表、索引与 WITHOUT ROWID 的内部遍历，补齐索引内部页记录。新增 BTreeRecord、逐条 callback、ScanSummary、累计 payload 与跨 B-tree/overflow 页预算；CLI 增加 records、index、scan。保持原有普通 rowid 表 API。

索引排序语义、SQL 列映射、全局数据库页归属报告仍未实现。真实 SQLite 对照验证 4407 条索引及 WITHOUT ROWID 原始记录。

新增同步 PageSource 与 open_source，宿主可提供按需读取的静态快照；BytesSource 与原有 open_database(Bytes) 保持兼容。独立消费测试验证第三方项目可实现 PageSource，并支持对已发布 Mooncakes 版本进行安装验证。

v0.2.0 已发布到 Mooncakes，真实 registry 消费项目的四后端检查、构建和测试通过，包括第三方 PageSource 实现。GitHub 提供对应 v0.2.0 标签。

新增 192 次确定性字节变更的回归扫描，验证损坏输入的错误行为及累计资源预算。

## 0.1.0

首个核心版本：SQLite 文件头、四种 B-tree 页头、rowid 表读取、record 与 Unicode 解码、overflow、schema、freelist 和 JSON CLI。

提供四后端测试与真实 SQLite 查询对照，并在独立消费工作区验证实际发布包。发布包排除本地申报书与开发指令。索引及 WITHOUT ROWID 记录读取、WAL、全局页归属检查不属于此版本。
