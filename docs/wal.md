# WAL 只读检查与最新已提交快照（v0.5.0）

实现依据 [SQLite WAL 磁盘格式](https://sqlite.org/fileformat.html#walformat)。所有 header/frame 字段按大端存储；checksum 输入的字节序由 magic 决定，使用累计模 2³² 加法。运行时无需 SQLite 引擎。

## 检查 WAL

`parse_wal_header(Bytes)` 验证 32 字节头、magic、3007000 格式版本、512–65536 页大小和头 checksum。头部损坏直接抛出 `Invalid`，未知版本为 `Unsupported`，超出当前表示范围为 `LimitExceeded`。

`inspect_wal(Bytes, max_frames=100000)` 返回连续有效帧、提交边界、最后已提交帧编号和提交后页数。帧编号从 1 开始；`byte_offset` 为 WAL 文件中的帧头位置。零字节 WAL 表示没有日志：`header=None`，不伪造 WAL 头；只有头的 WAL 也可用，帧列表为空。

检查遇到第一个无效帧即停止，不会跳过坏帧搜索后续提交。`stop_reason` 区分 EOF、帧截断、salt 不匹配、累计 checksum 不匹配、无效页号和帧限额；`stop_offset` 为该帧起点，`trailing_bytes` 是该起点之后尚未接受的全部字节。有效但未提交的帧仍列在 `frames` 中，位于 `committed_frames` 之后，不属于最新已提交快照。帧检查不解码数据库页内容。

salt 不匹配可能是 WAL reset 后未覆盖的旧尾部，checksum 或截断也可能是写入中断；报告只给出实际停止原因，不推断故障来源或数据库身份。检查上限不足不表示扫描完成。

## 覆盖数据源

`WalSource::new(base, wal, tail_policy?, max_frames?)` 接收第三方同步 `PageSource` 和不可变 WAL 字节，提供只读 `PageSource`。`source.inspection()` 提供帧报告，`source.page_count()` 提供提交后逻辑页数。使用 `open_wal_source(source, limits?)` 得到原有 `Database`，或用 `open_wal_database(db_bytes, wal_bytes, ...)` 简化内存输入。打开 WAL 视图时使用这两个专用入口，普通 `open_source` 仍按主文件页 1 的原始声明确定页数。覆盖源不会改写原始页 1 字节，因此 `header().declared_pages` 可能与权威的 `page_count()` 不同。

默认 `RejectInvalidTail` 拒绝非 EOF 的异常尾部，包括 reset 后的旧 salt。调用者先检查报告，再显式选择 `UseValidPrefix`，可按 SQLite 的有效前缀规则忽略首个无效帧及其后全部内容，只读取此前最后一个完整提交。合法的未提交尾帧在两种策略中都不进入快照。帧限额即使使用前缀策略也抛出 `LimitExceeded`，避免把较早的提交当作最新提交。

读取同一页时采用最后提交边界之前的最新有效帧，否则读取主文件。提交后的数据库页数是权威边界，不以页 1 的旧声明值覆盖它，也不暴露逻辑末尾后的物理页。缩小提交使此前高页号版本失效，再次增长的新页必须由 WAL 覆盖；缺页时拒绝构造快照，避免读取截断残留。索引反向扫描一次构建，额外内存与已接受帧及不同覆盖页数成正比；范围读取支持跨页且不写入主文件。

没有提交时保留主文件快照；空主文件仅在 WAL 提供完整已提交页 1 和全部增长页时可初始化。页大小不匹配、主文件非整页、缺失增长页或逻辑大小超出 Int 地址范围会失败。宿主短读与 I/O 错误沿用 `PageSource` 的错误契约。

## 一致副本与使用范围

宿主必须保证 db/WAL 来自同一数据库、同一静态快照，且使用期间不变。WAL salt/checksum 不含主文件身份信息，不能检测所有不匹配副本。直接先后复制仍被写入的文件不构成一致快照；本库不实现文件锁、`-shm`、在线并发读协议、checkpoint 或写事务。

只读取最新已提交快照，不提供任意历史事务视图：checkpoint 可能已把较新页面写回主文件，历史 WAL 边界不能独立恢复旧主文件内容。全库/树/页检查继续复用原有 API 与预算；成功构造 WAL 快照不等同于 SQLite `integrity_check`。大文件 64 位寻址、异步范围读取及取消属于后续版本。

## CLI

```sh
node tools/inspect.cjs snapshot.wal wal-inspect
node tools/inspect.cjs snapshot.db --wal snapshot.wal wal-info
node tools/inspect.cjs snapshot.db --wal snapshot.wal schema
node tools/inspect.cjs snapshot.db --wal snapshot.wal rows items 10
node tools/inspect.cjs snapshot.db --wal snapshot.wal inspect-details
node tools/inspect.cjs snapshot.db --wal snapshot.wal summary
```

选项放在数据库路径后、命令前；`--wal-prefix` 对应显式 `UseValidPrefix`。`wal-inspect` 直接接收 WAL 文件，不读取主文件；初始化错误写 stderr，能构造帧报告时写 stdout，EOF 为退出码 0、异常尾部为 1、帧限额为 2。有效未提交尾帧不属于异常尾部。`wal-info` 必须提供 `--wal`，显示帧报告、覆盖后的文件头/逻辑页数和采用的尾部策略。

原有查询、页面、检查与摘要命令都可使用 WAL 覆盖视图。严格模式无法构造快照时写 stderr；显式选择前缀后，普通命令沿用自身输出及退出码契约，`wal-info` 仍保留停止原因。没有 `--wal` 的原有调用保持原有含义，CLI 不自动读取相邻的 `-wal` 文件。HTML 离线演示暂只接收静态主文件，不能用它替代 db/WAL 配对读取。

## 对照验证

`python tools/verify_wal_oracle.py` 由 SQLite 生成多事务日志，将独立副本交给 SQLite 自行恢复，以 SQL 查询、schema、逻辑页数及 integrity_check 作为 oracle。另一份原始副本交给 MoonBit，逐条核对普通表、索引及 WITHOUT ROWID 记录，并核对页归属与诊断。字节序转换后的 WAL 也由 SQLite 引擎读取，不仅与 Python 的字段计算比较。覆盖 512/4096/65536 页、三种文本编码、未提交尾帧、异常中间帧、reset 旧 salt、缩小/增长和空日志；验证源文件未被改写。
