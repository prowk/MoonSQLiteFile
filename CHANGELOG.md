# 更新记录

## 未发布

修复空叶页跳过 B-tree 深度验证的问题；深度不一致的树现在返回 `Invalid`，检查报告为 `Failed`，并保留此前成功解码的记录数。

补齐四种 B-tree 页的 cell 空间覆盖校验，包含 varint、子页指针、页内 payload、overflow 指针及最小四字节填充；拒绝 cell 互相重叠、cell 与 freeblock 内容重叠、间距不足的 freeblock 链、未登记空闲区间和错误碎片计数。页面校验不读取 overflow 链、不分配完整 payload；公开 API 和 JSON 结构不变。行为收紧：`page` 及扫描现在验证所访问页面中全部 cell 的空间，显式 limit 读取前缀也可能因同页其他 cell 的空间损坏而失败。

新增真实 SQLite 删除与变长更新后的空间对照，覆盖四种 B-tree、512–65536 字节页与三种文本编码，并对碎片计数和未登记空闲区间进行受控损坏验证。上述变化用于开发中的 v0.4.0，尚未发布新包。

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
