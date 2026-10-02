# 更新记录

## 0.2.0

统一普通表、索引与 WITHOUT ROWID 的内部遍历，补齐索引内部页记录。新增 BTreeRecord、逐条 callback、ScanSummary、累计 payload 与跨 B-tree/overflow 页预算；CLI 增加 records、index、scan。保持原有普通 rowid 表 API。

索引排序语义、SQL 列映射、全局数据库页归属报告仍未实现。真实 SQLite 对照验证 4407 条索引及 WITHOUT ROWID 原始记录。

新增同步 PageSource 与 open_source，宿主可提供按需读取的静态快照；BytesSource 与原有 open_database(Bytes) 保持兼容。独立消费测试验证第三方项目可实现 PageSource，并支持对已发布 Mooncakes 版本进行安装验证。

v0.1.0 已发布到 Mooncakes，真实 registry 消费项目的四后端检查、构建和测试通过。

## 0.1.0

首个核心版本：SQLite 文件头、四种 B-tree 页头、rowid 表读取、record 与 Unicode 解码、overflow、schema、freelist 和 JSON CLI。

提供四后端测试与真实 SQLite 查询对照，并在独立消费工作区验证实际发布包。发布包排除本地申报书与开发指令。索引及 WITHOUT ROWID 记录读取、WAL、全局页归属检查不属于此版本。
