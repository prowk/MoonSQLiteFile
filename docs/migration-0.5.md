# 升级到 v0.5.0

本版新增 WAL 格式检查、最新已提交快照和 CLI 配对输入。安装：

```sh
moon add prowk/moonsqlitefile@0.5.0
```

## API 与行为

对当前代码重新生成接口，并核对 v0.3.0 的 85 项及 v0.4.0 的 123 项公开声明：现有签名、结构字段、枚举分支与 PageSource 契约保持原有形式。普通 `open_database` / `open_source` 继续读取静态主文件，不自动发现或应用 WAL。新能力采用独立类型和入口，没有改变旧错误枚举。

用 `inspect_wal` 读取帧和提交报告；用 `WalSource::new` 包装第三方同步源，再调用 `open_wal_source`，或直接 `open_wal_database(db_bytes, wal_bytes)`。专用打开入口按最后一个已接受提交的页数初始化 Database；普通 `open_source(WalSource)` 会按原始页 1 声明解释，不应作为 WAL 快照入口。`header().declared_pages` 保留原始字节，读取逻辑边界以 `page_count()` 为准。

默认 `RejectInvalidTail` 拒绝首个异常尾帧，包括 reset 后的旧 salt。先检查报告，再显式 `UseValidPrefix` 可忽略无效尾部，只采用此前最后一个完整提交；不会跳过中间坏帧寻找后续提交。合法未提交尾帧始终不进入快照。header 损坏或未知版本不能用前缀策略绕过；帧限额不足仍抛出 `LimitExceeded`，不假装最新快照读取成功。

零字节 WAL 表示无日志，报告 `header=None`；非零但少于 32 字节的 WAL 是损坏输入。合法头但无提交时保留主文件快照。新报告中的帧编号从 1 开始，偏移是 WAL 文件偏移；不要与页内诊断偏移混用。

## CLI

```sh
node tools/inspect.cjs copy.wal wal-inspect
node tools/inspect.cjs copy.db --wal copy.wal wal-info
node tools/inspect.cjs copy.db --wal copy.wal inspect-details
node tools/inspect.cjs copy.db --wal copy.wal --wal-prefix summary
```

选项放在主文件路径之后、命令之前，所有原有数据库命令均可使用覆盖视图。旧命令的 JSON 结构保持原有形式；`wal-info` 提供额外的帧报告和快照元信息，`wal-inspect` 直接检查 WAL 而不读取主文件。完整退出码与尾部策略见 [WAL 文档](wal.md)。HTML 示例仍只选择单个静态主文件，不接收 WAL；需要 WAL 的场景使用库或 CLI。

## 副本责任与限制

必须提供来自同一数据库、同一时刻且之后不变的 db/WAL 副本。salt/checksum 不能验证主文件身份，库没有获取在线一致副本的锁协议。不执行 SQL、不写入文件、不执行 checkpoint、不读取 shm，也不提供任意历史事务视图。WAL 快照的结构检查不等同于 SQLite integrity_check。

输入仍采用同步 Int 寻址，WAL 默认最多验证 100000 帧；累计扫描预算仍由原有 Limits 和检查参数控制。64 位与异步读取将在后续版本实现。当前 release 工具链、Node.js 22 与 Python 3.13 的开发要求沿用 v0.4.0；纯库 API 没有新增运行时依赖。

四后端回归、SQLite 独立恢复对照和外部消费都覆盖新接口。发布包消费现已在四后端实际运行；WAL 模糊失败样本必须同时保留 `.base.sqlite`，详见[重放说明](fuzzing.md)。
