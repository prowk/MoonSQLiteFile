# v0.8.0 升级说明

本版为待发布开发版，重点为目录与工程契约。`prowk/moonsqlitefile` 对外导入路径、公开类型归属、结构体可见字段、枚举分支及函数声明保持；兼容检查包含正式 v0.7.0 的 237 项基线。新增源码注释不会改变默认预算和报告语义。

源码贡献者需将根目录 `.mbt`、`moon.pkg` 和 `pkg.generated.mbti` 的路径更新为 `src/`。CLI 和 MoonBit 示例位于 `src/cmd/` 与 `src/examples/`，例如 `moon run --target js src/examples/basic`；HTML 示例和 Node launcher 的路径不变。原外部 MoonBit 消费者无需把导入写成 `prowk/moonsqlitefile/src`。

公开契约继续区分旧 `PageSource` 和新 `RangeSource`：旧宿主抛 `Invalid` 时，单树/全库报告可能为 Failed；新源的 HostFailure、ShortRead、RangeOutOfBounds 映射成 `Unsupported("source/...")`，检查为 Incomplete。单页读取失败均为 Incomplete。这是保留历史行为，不能仅从 Failed 推断损坏。初始化失败没有部分报告。

CLI 继续保留 17 个命令的输出、退出码和错误通道；本版以 v0.7.0 正式 tag 的 22 个场景作对照，包含空值、数值/文本类型、诊断、未完成报告及 WAL。异步 WAL 的 64 位 JSON 字段仍为十进制文本，与安全整数范围内输出数字的 CLI 分开消费。

工具链与支持范围见[支持矩阵](support.md)，贡献与复现方式见[贡献指南](../CONTRIBUTING.md)。测试数据保留在测试专用文件，消费者正常构建不需要 Python 或 SQLite。异步包版本同步为 0.8.0，仍只本地打包、未发布 npm。

本版不新增 SQL 执行、写入、在线锁/快照协议或恢复，不改变 `Complete` 的结构检查范围。单条 payload 完整解码，全库归属、遍历和 WAL 索引分别需要预算。直接 file:// 打开仍受浏览器验收能力限制，不能将 HTTP 载入后断网替代为直接打开成功。
