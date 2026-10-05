# 同步范围读取升级说明（v0.6.0 内部里程碑）

v0.6.0 未单独发布，本页内容随 v0.7.0 一并交付。由 v0.5.0 升级时，请同时阅读[v0.7.0 升级说明](migration-0.7.md)；本页的“本版”指同步范围读取里程碑。

v0.6.0 修复三项已复现缺陷，并新增同步 64 位范围读取。v0.3.0、v0.4.0 和 v0.5.0 的公开声明继续受兼容基线保护；既有公开结构体的可见字段和错误枚举分支保持原有形式。`Database` 新内部字段为私有，兼容检查只忽略生成接口中的私有字段占位注释，不忽略任何公开字段或类型变化。

## 已有行为变化

- SQLite 正常产生的四字节及更长空闲间隙不再仅因长度被拒绝；统一累计所有未覆盖字节并核对页头 fragmented bytes，同时保留重叠、freeblock 链、越界和 60 字节上限。碎片计数不匹配统一定位为 `FragmentCount` / `fragment_count`，原有 `UntrackedSpace` 枚举仍保留，但不再用于提前拒绝这些间隙。
- 非根空 B-tree 页现在返回 `Invalid` / `Failed`，防止损坏文件缺失记录却以完整结果返回。空表/索引叶根仍可读取；仅页 1 可以保留零 cell 的内部虚拟根，实际子页须非空。叶页深度、键边界及重复页检查继续生效。
- CLI 与离线界面显示 `invalid:`、`unsupported:` 或 `limit_exceeded:` 及原始具体消息，替代没有原因的类型名称。报告 JSON 的格式错误分类继续使用已有字段。
- 超过 Int 表示范围的页指针明确返回 `LimitExceeded`，不会转换为负数。

## 切换到范围读取

旧 `PageSource` 实现无需修改。要使用新的宿主错误分类，调用 `open_range_source(PageSourceAdapter.new(source))`；要读取超过 2 GiB 的文件，应直接实现 `RangeSource`，以 `Int64` 返回长度和接受偏移。单次字节数、页号及 payload 长度继续为 `Int`，本版最多支持 2147483647 页。

主文件用 `open_range_source`；WAL 用 `RangeWalSource.new(base, wal)` 和 `open_range_wal_source`。两份输入均按需读取，不要求将完整 WAL 放入 `Bytes`。可加 `CachedSource`；帧、覆盖索引、遍历及报告预算分开设置。

旧 `Database.source` 字段继续提供 Int 接口视图，范围入口超过 Int 长度时旧视图返回长度 -1，并拒绝读取；改用 `Database.source64()`。旧 `open_source` 的源身份及错误传播不变。

新读取接口将 `SourceError` 转为带 `source/` 分类的 `Unsupported`，所以树和全局报告的宿主失败均为 `Incomplete`。旧源直接抛出的 `SqliteError` 保持历史报告语义；不会仅凭旧 `Failed` 或读取阶段诊断判断文件损坏。初始化阶段没有报告时错误直接抛出。

## CLI 选项与输出

原有命令继续可用。CLI 默认按范围读取，主文件缓存 256 个 4096 字节块；提供 `--cache-pages`、`--max-frames`、`--max-overlay-pages`、`--max-pages`、`--max-report-pages`、`--max-rows` 和 `--max-issues`。`--io-stats` 将测量数据写 stderr，解析 stderr 的程序需显式处理这一选项。

WAL 偏移的 JSON 数值保持至 JavaScript 精确整数边界；更大的值输出十进制字符串，消费端应同时接受两者。报告状态与退出码 0/1/2 保持一致；参数和初始化失败仍为退出码 1。

## 使用边界

范围读取不提供在线锁、快照获取、异步 I/O、SQL 执行、写入或恢复。输入必须是同一时刻的一致静态副本，单条 payload 仍完整解码，全局报告仍按页数占用内存。离线 HTML 的浏览器限制保持现有范围。

完整接口、预算、错误映射及验收方法见[范围读取契约](range-source.md)，WAL 语义见 [WAL 契约](wal.md)。

## CLI payload 预算与验收

CLI 新增 `--max-payload-bytes`（单条 Int）和 `--max-total-payload-bytes`（累计 UInt64），保留 16 MiB / 64 MiB 默认值。大数据完整扫描需独立提高累计预算；集合读取命令仍收集数组，不受新增累计参数控制。适配器自行发现的越界和短读现在分别为 RangeOutOfBounds 和 ShortRead，只有旧源实际抛出的错误为 HostFailure；经 Database 映射后的报告仍为 Incomplete。详见[范围契约](range-source.md)。

CI 纳入合法大 payload、高位 WAL、重复更新基准及范围/缓存/适配器/故障差分 fuzz，并保存成本证据。发布 tag、附件、对应提交的 GitHub CI 和 Mooncakes registry 消费证据统一记录在 v0.7.0 Release。
