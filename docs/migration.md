# 历史升级说明

本页保留各版本当时的升级要求；当前使用范围见[支持说明](support.md)，当前用法见[使用指南](usage.md)。v0.8.1、v0.8.2 为本地源码交付，尚未发布包或 Release。

<a id="v040"></a>

## v0.4.0：页面空间与诊断

v0.4.0 完成静态页面空间检查、可定位诊断、统计与离线展示。安装：

```sh
moon add prowk/moonsqlitefile@0.4.0
```

<a id="v040-行为变化"></a>

### 行为变化

`Database.page` 及记录扫描现在验证访问页中所有 cell 的完整字节区间，与 freeblock 一起核对空间覆盖和碎片计数。此前被接受的 cell/freeblock 重叠、未登记空闲区间、碎片计数错误会返回 `Invalid`。即使使用小 `limit` 读取前缀，同页未选中的 cell 存在空间损坏也会导致该页失败；失败页中的记录不会计入已解码进度。空叶页也参与树深度检查，不能再跳过深度不一致。

合法数据库无需修改存储格式。依赖旧版宽松行为读取损坏页的工具应显式处理失败；本版本没有尽力恢复接口。损坏数据恢复属于后续独立能力，不应将严格读取失败静默当作成功。

<a id="v040-api-与报告"></a>

### API 与报告

对 v0.3.0 的生成接口逐项审查：现有函数签名、公开结构字段、枚举分支和 `PageSource` 契约保持原有形式，新增能力使用独立类型和方法；CI 对照固定的 v0.3.0 接口，独立消费项目验证新旧调用。当前工具链支持的是源码消费，没有跨编译器版本的二进制 ABI 承诺。

| 需求 | 新入口 | 范围 |
| --- | --- | --- |
| 单页空间与失败分类 | `db.inspect_page(number)` | 仅指定 B-tree 页，不读取 overflow 链或 record |
| 单树失败位置 | `db.inspect_btree_details(root)` | 原报告及可选位置，同一次扫描 |
| 全库诊断位置 | `db.inspect_database_details()` | 原报告及同序、同长度的定位诊断 |
| 已观察页和对象占页 | `report.summarize()` | 纯汇总，不读取源，冲突引用不重复计数 |

`inspect_page` 读取失败为 `Incomplete` / `PageRead`。现有树/全库报告仍沿用 `SqliteError` 状态映射：宿主 `Invalid` 可表现为 `Failed`，详细位置的 `ReadPage` 表示没有取得完整页面，不能据此宣布文件损坏。位置未知时为 `None`；位置指向检查字段或 cell 起点，不保证解码 payload 内部的精确字节地址。

空间分项合计一页。声明 payload 不意味着 overflow 链或内容已验证；对象占页字节包含页头、元数据与空闲区，不是有效数据量。检查未完成时汇总只表示已观察部分；`Complete` 不等同于 SQLite `integrity_check`。

<a id="v040-clijson-与工具链"></a>

### CLI、JSON 与工具链

旧命令的 JSON 字段保持原有结构；新命令为 `page-inspect`、`tree-inspect`、`inspect-details`、`summary-json`、`viewer-data`，`summary` 输出中文文本。自动消费程序应按命令选择格式。报告命令退出码 `0/1/2` 分别表示完成/失败/未完成；参数及初始化错误写 stderr。

64 位整数、payload 累计值与占页字节仍以十进制字符串输出。详细定位与诊断同步截断，必须读取覆盖标记；界面从 `viewer-data` 的同一次检查报告导航，不能把未认领页一概当作孤儿。

使用 MoonBit release 工具链。发布验收记录 `moon 0.1.20260920`、`moonc 0.10.14`；CI 另使用当次安装的 release 工具链检查四后端。CLI 和模糊测试使用 Node.js 22，完整开发验证使用 Python 3.13。新增纯库 API 无需 Node.js 或 SQLite 引擎；没有新增运行时依赖。离线示例使用完整文件与 Blob Worker，暂不提供异步 `PageSource`。

<a id="v040-后续-api-演进"></a>

### 后续 API 演进

0.x 功能版本可以在有明确迁移说明的前提下收紧行为或调整 API；补丁用于保持既定契约的修复。新增字段或枚举分支会影响公开构造和穷举匹配，应先评估独立消费代码。优先新增独立报告、方法或构造入口，再在规划的功能版本中调整旧契约。后续 64 位与异步源将保留当前小文件接口；v1.0 再固定稳定契约。

范围细节见[架构说明](architecture.md)，离线演示见[使用说明](../examples/offline-viewer/README.md)，模糊测试见[重放文档](../CONTRIBUTING.md#模糊测试与重放)。

<a id="v050"></a>

## v0.5.0：WAL 静态快照

本版新增 WAL 格式检查、最新已提交快照和 CLI 配对输入。安装：

```sh
moon add prowk/moonsqlitefile@0.5.0
```

<a id="v050-api-与行为"></a>

### API 与行为

对当前代码重新生成接口，并核对 v0.3.0 的 85 项及 v0.4.0 的 123 项公开声明：现有签名、结构字段、枚举分支与 PageSource 契约保持原有形式。普通 `open_database` / `open_source` 继续读取静态主文件，不自动发现或应用 WAL。新能力采用独立类型和入口，没有改变旧错误枚举。

用 `inspect_wal` 读取帧和提交报告；用 `WalSource::new` 包装第三方同步源，再调用 `open_wal_source`，或直接 `open_wal_database(db_bytes, wal_bytes)`。专用打开入口按最后一个已接受提交的页数初始化 Database；普通 `open_source(WalSource)` 会按原始页 1 声明解释，不应作为 WAL 快照入口。`header().declared_pages` 保留原始字节，读取逻辑边界以 `page_count()` 为准。

默认 `RejectInvalidTail` 拒绝首个异常尾帧，包括 reset 后的旧 salt。先检查报告，再显式 `UseValidPrefix` 可忽略无效尾部，只采用此前最后一个完整提交；不会跳过中间坏帧寻找后续提交。合法未提交尾帧始终不进入快照。header 损坏或未知版本不能用前缀策略绕过；帧限额不足仍抛出 `LimitExceeded`，不假装最新快照读取成功。

零字节 WAL 表示无日志，报告 `header=None`；非零但少于 32 字节的 WAL 是损坏输入。合法头但无提交时保留主文件快照。新报告中的帧编号从 1 开始，偏移是 WAL 文件偏移；不要与页内诊断偏移混用。

<a id="v050-cli"></a>

### CLI

```sh
node tools/inspect.cjs copy.wal wal-inspect
node tools/inspect.cjs copy.db --wal copy.wal wal-info
node tools/inspect.cjs copy.db --wal copy.wal inspect-details
node tools/inspect.cjs copy.db --wal copy.wal --wal-prefix summary
```

选项放在主文件路径之后、命令之前，所有原有数据库命令均可使用覆盖视图。旧命令的 JSON 结构保持原有形式；`wal-info` 提供额外的帧报告和快照元信息，`wal-inspect` 直接检查 WAL 而不读取主文件。完整退出码与尾部策略见 [WAL 文档](wal.md)。HTML 示例仍只选择单个静态主文件，不接收 WAL；需要 WAL 的场景使用库或 CLI。

<a id="v050-副本责任与限制"></a>

### 副本责任与限制

必须提供来自同一数据库、同一时刻且之后不变的 db/WAL 副本。salt/checksum 不能验证主文件身份，库没有获取在线一致副本的锁协议。不执行 SQL、不写入文件、不执行 checkpoint、不读取 shm，也不提供任意历史事务视图。WAL 快照的结构检查不等同于 SQLite integrity_check。

输入仍采用同步 Int 寻址，WAL 默认最多验证 100000 帧；累计扫描预算仍由原有 Limits 和检查参数控制。64 位与异步读取将在后续版本实现。当前 release 工具链、Node.js 22 与 Python 3.13 的开发要求沿用 v0.4.0；纯库 API 没有新增运行时依赖。

四后端回归、SQLite 独立恢复对照和外部消费都覆盖新接口。发布包消费现已在四后端实际运行；WAL 模糊失败样本必须同时保留 `.base.sqlite`，详见[重放说明](../CONTRIBUTING.md#模糊测试与重放)。

<a id="v060"></a>

## v0.6.0（内部里程碑，未单独发布）：同步范围读取

v0.6.0 未单独发布，本页内容随 v0.7.0 一并交付。由 v0.5.0 升级时，请同时阅读[v0.7.0 升级说明](migration.md#v070)；本页的“本版”指同步范围读取里程碑。

v0.6.0 修复三项已复现缺陷，并新增同步 64 位范围读取。v0.3.0、v0.4.0 和 v0.5.0 的公开声明继续受兼容基线保护；既有公开结构体的可见字段和错误枚举分支保持原有形式。`Database` 新内部字段为私有，兼容检查只忽略生成接口中的私有字段占位注释，不忽略任何公开字段或类型变化。

<a id="v060-已有行为变化"></a>

### 已有行为变化

- SQLite 正常产生的四字节及更长空闲间隙不再仅因长度被拒绝；统一累计所有未覆盖字节并核对页头 fragmented bytes，同时保留重叠、freeblock 链、越界和 60 字节上限。碎片计数不匹配统一定位为 `FragmentCount` / `fragment_count`，原有 `UntrackedSpace` 枚举仍保留，但不再用于提前拒绝这些间隙。
- 非根空 B-tree 页现在返回 `Invalid` / `Failed`，防止损坏文件缺失记录却以完整结果返回。空表/索引叶根仍可读取；仅页 1 可以保留零 cell 的内部虚拟根，实际子页须非空。叶页深度、键边界及重复页检查继续生效。
- CLI 与离线界面显示 `invalid:`、`unsupported:` 或 `limit_exceeded:` 及原始具体消息，替代没有原因的类型名称。报告 JSON 的格式错误分类继续使用已有字段。
- 超过 Int 表示范围的页指针明确返回 `LimitExceeded`，不会转换为负数。

<a id="v060-切换到范围读取"></a>

### 切换到范围读取

旧 `PageSource` 实现无需修改。要使用新的宿主错误分类，调用 `open_range_source(PageSourceAdapter.new(source))`；要读取超过 2 GiB 的文件，应直接实现 `RangeSource`，以 `Int64` 返回长度和接受偏移。单次字节数、页号及 payload 长度继续为 `Int`，本版最多支持 2147483647 页。

主文件用 `open_range_source`；WAL 用 `RangeWalSource.new(base, wal)` 和 `open_range_wal_source`。两份输入均按需读取，不要求将完整 WAL 放入 `Bytes`。可加 `CachedSource`；帧、覆盖索引、遍历及报告预算分开设置。

旧 `Database.source` 字段继续提供 Int 接口视图，范围入口超过 Int 长度时旧视图返回长度 -1，并拒绝读取；改用 `Database.source64()`。旧 `open_source` 的源身份及错误传播不变。

新读取接口将 `SourceError` 转为带 `source/` 分类的 `Unsupported`，所以树和全局报告的宿主失败均为 `Incomplete`。旧源直接抛出的 `SqliteError` 保持历史报告语义；不会仅凭旧 `Failed` 或读取阶段诊断判断文件损坏。初始化阶段没有报告时错误直接抛出。

<a id="v060-cli-选项与输出"></a>

### CLI 选项与输出

原有命令继续可用。CLI 默认按范围读取，主文件缓存 256 个 4096 字节块；提供 `--cache-pages`、`--max-frames`、`--max-overlay-pages`、`--max-pages`、`--max-report-pages`、`--max-rows` 和 `--max-issues`。`--io-stats` 将测量数据写 stderr，解析 stderr 的程序需显式处理这一选项。

WAL 偏移的 JSON 数值保持至 JavaScript 精确整数边界；更大的值输出十进制字符串，消费端应同时接受两者。报告状态与退出码 0/1/2 保持一致；参数和初始化失败仍为退出码 1。

<a id="v060-使用边界"></a>

### 使用边界

范围读取不提供在线锁、快照获取、异步 I/O、SQL 执行、写入或恢复。输入必须是同一时刻的一致静态副本，单条 payload 仍完整解码，全局报告仍按页数占用内存。离线 HTML 的浏览器限制保持现有范围。

完整接口、预算、错误映射及验收方法见[范围读取契约](range-source.md)，WAL 语义见 [WAL 契约](wal.md)。

<a id="v060-cli-payload-预算与验收"></a>

### CLI payload 预算与验收

CLI 新增 `--max-payload-bytes`（单条 Int）和 `--max-total-payload-bytes`（累计 UInt64），保留 16 MiB / 64 MiB 默认值。大数据完整扫描需独立提高累计预算；集合读取命令仍收集数组，不受新增累计参数控制。适配器自行发现的越界和短读现在分别为 RangeOutOfBounds 和 ShortRead，只有旧源实际抛出的错误为 HostFailure；经 Database 映射后的报告仍为 Incomplete。详见[范围契约](range-source.md)。

CI 纳入合法大 payload、高位 WAL、重复更新基准及范围/缓存/适配器/故障差分 fuzz，并保存成本证据。发布 tag、附件、对应提交的 GitHub CI 和 Mooncakes registry 消费证据统一记录在 v0.7.0 Release。

<a id="v070"></a>

## v0.7.0：范围读取与异步宿主

v0.7.0 从已发布的 v0.5.0 直接升级，合入 v0.6.0 内部里程碑，未单独发布 v0.6.0。

从 v0.5.0 升级须同时阅读[同步范围读取与行为变化](migration.md#v060)：非根空 B-tree 页现在拒绝，合法碎片不再被误拒，CLI 错误信息和范围源错误分类更精确；超过 Int 长度时须使用 `Database.source64()`。CLI 默认单条/累计 payload 预算仍为 16 MiB / 64 MiB，可分别配置。

原同步入口、公开结构体及错误枚举保持；v0.3.0–v0.6.0 的公开声明基线继续核对。新增可供页游标，同步扫描/WAL/全库检查改为驱动同一状态机，原 JSON 契约仍由 SQLite 与消费验证覆盖。

异步能力位于独立 JS 包，不需要给 MoonBit 核心添加 async 或宿主依赖。核心仍支持四后端，异步包当前验证 Node 22.14 和 Chrome；其他宿主未声明支持。构建、接口、取消及源接管规则见[异步范围读取](async-source.md)。异步包以 v0.7.0 Release tarball 附件提供，也可本地构建；尚未发布 npm registry。

异步源使用 BigInt 长度/偏移，并以 Promise 返回严格长度的 Uint8Array。不能直接传入原同步 PageSource；用 BlobSource/openFileSource 或实现异步协议。记录扫描支持 await 和异步迭代器背压；break、取消和失败都会释放游标，消费方应检查完整状态并在 finally 中关闭数据库。

离线查看器现在按 Blob 分块读取 db 与可选 WAL，移除 64 MiB 文件长度限制；默认累计 payload 仍为 64 MiB，单条仍为 16 MiB，全库页数和记录数仍有界。默认检查时间从 30 秒调整为可设置的 120 秒，预算不足或取消返回已观察结果。直接 file:// 打开仍缺真实验收，实际已完成本机 HTTP 载入后断网测试；该差别在验收记录中保留。

新增枚举使用独立类型，未给原枚举添加分支。新增 WalCursor 供应完整 WAL 头/帧；取消的游标不能构造最新快照。异步 WAL JSON 64 位字段为十进制文本，与 CLI 在安全整数范围内使用数字的输出约定不同，请按所属入口消费。

Complete 仍仅代表所声明结构检查完成，不是 SQLite integrity_check；SQL 执行、写入、在线锁/快照协议、恢复及表/索引记录一致性不在此版本范围。

<a id="v080"></a>

## v0.8.0：源码目录与工程契约

本版重点为目录与工程契约。`prowk/moonsqlitefile` 对外导入路径、公开类型归属、结构体可见字段、枚举分支及函数声明保持；兼容检查包含正式 v0.7.0 的 237 项基线。新增源码注释不会改变默认预算和报告语义。

源码贡献者需将根目录 `.mbt`、`moon.pkg` 和 `pkg.generated.mbti` 的路径更新为 `src/`。CLI 和 MoonBit 示例位于 `src/cmd/` 与 `src/examples/`，例如 `moon run --target js src/examples/basic`；HTML 示例和 Node launcher 的路径不变。原外部 MoonBit 消费者无需把导入写成 `prowk/moonsqlitefile/src`。

公开契约继续区分旧 `PageSource` 和新 `RangeSource`：旧宿主抛 `Invalid` 时，单树/全库报告可能为 Failed；新源的 HostFailure、ShortRead、RangeOutOfBounds 映射成 `Unsupported("source/...")`，检查为 Incomplete。单页读取失败均为 Incomplete。这是保留历史行为，不能仅从 Failed 推断损坏。初始化失败没有部分报告。

CLI 继续保留 17 个命令的输出、退出码和错误通道；本版以 v0.7.0 正式 tag 的 22 个场景作对照，包含空值、数值/文本类型、诊断、未完成报告及 WAL。异步 WAL 的 64 位 JSON 字段仍为十进制文本，与安全整数范围内输出数字的 CLI 分开消费。

工具链与支持范围见[支持矩阵](support.md)，贡献与复现方式见[贡献指南](../CONTRIBUTING.md)。测试数据保留在测试专用文件，消费者正常构建不需要 Python 或 SQLite。异步包版本同步为 0.8.0，作为 v0.8.0 Release tarball 附件提供，也可本地构建；未发布 npm registry。

本版不新增 SQL 执行、写入、在线锁/快照协议或恢复，不改变 `Complete` 的结构检查范围。单条 payload 完整解码，全库归属、遍历和 WAL 索引分别需要预算。直接 file:// 打开仍受浏览器验收能力限制，不能将 HTTP 载入后断网替代为直接打开成功。

<a id="v081"></a>

## v0.8.1：整数参数修复

此版本已在源码中实现，尚未发布包或 Release。已发布安装版本仍为 v0.8.0。

异步页号和整数预算不再静默截断小数：`db.scan(3.9)`、`{limit: 1.9}` 现在抛 TypeError。调用方应传入符合[异步契约](async-source.md#扫描背压和部分结果)的整数；不要自动向下取整来隐藏上游参数错误。整数预算只接受 number；累计 payload 只接受 UInt64 BigInt 或十进制文本。无效类型、无效数值和越界值也明确拒绝。

`scan` 构造和预算入口的错误直接抛出或拒绝 Promise；它们发生在游标创建前，没有可用的部分扫描报告。`inspectPage` 保留非法页号的 incomplete 报告。打开失败默认关闭接管的主文件及 WAL，`closeSources: false` 时原始源仍由调用者释放。合法整数、扫描 limit 为 0、源接管、取消及已发布输出约定保持。

核心及异步公开声明继续兼容正式 v0.8.0，CLI 同时核对正式 v0.7.0、v0.8.0 的全部命令契约。兼容新增不再因符号数量或导出集合严格相等被误拒，历史基线保留；结构字段和枚举分支变化仍需评估兼容性。

<a id="v082"></a>

## v0.8.2（未发布）

贡献者提交前和 CI 改为调用 `python tools/verify.py`；保留原 34 项检查及固定/latest 通道，新增维护契约检查。单项脚本继续可独立运行，不能代替完整验收。

源码目录职责集中在[架构](architecture.md)，当前范围集中在[支持说明](support.md)，历史迁移集中在本页。仅用于旧链接的导航文档已删除，历史文档可在对应 Release 或 tag 查看；公开接口和报告不因文档移动而改变。安装仍使用已发布的 v0.8.0；本地源码和异步构建版本为 0.8.2。
