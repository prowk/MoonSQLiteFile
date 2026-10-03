# 升级到 v0.4.0

v0.4.0 完成静态页面空间检查、可定位诊断、统计与离线展示。安装：

```sh
moon add prowk/moonsqlitefile@0.4.0
```

## 行为变化

`Database.page` 及记录扫描现在验证访问页中所有 cell 的完整字节区间，与 freeblock 一起核对空间覆盖和碎片计数。此前被接受的 cell/freeblock 重叠、未登记空闲区间、碎片计数错误会返回 `Invalid`。即使使用小 `limit` 读取前缀，同页未选中的 cell 存在空间损坏也会导致该页失败；失败页中的记录不会计入已解码进度。空叶页也参与树深度检查，不能再跳过深度不一致。

合法数据库无需修改存储格式。依赖旧版宽松行为读取损坏页的工具应显式处理失败；本版本没有尽力恢复接口。损坏数据恢复属于后续独立能力，不应将严格读取失败静默当作成功。

## API 与报告

对 v0.3.0 的生成接口逐项审查：现有函数签名、公开结构字段、枚举分支和 `PageSource` 契约保持原有形式，新增能力使用独立类型和方法；CI 对照固定的 v0.3.0 接口，独立消费项目验证新旧调用。当前工具链支持的是源码消费，没有跨编译器版本的二进制 ABI 承诺。

| 需求 | 新入口 | 范围 |
| --- | --- | --- |
| 单页空间与失败分类 | `db.inspect_page(number)` | 仅指定 B-tree 页，不读取 overflow 链或 record |
| 单树失败位置 | `db.inspect_btree_details(root)` | 原报告及可选位置，同一次扫描 |
| 全库诊断位置 | `db.inspect_database_details()` | 原报告及同序、同长度的定位诊断 |
| 已观察页和对象占页 | `report.summarize()` | 纯汇总，不读取源，冲突引用不重复计数 |

`inspect_page` 读取失败为 `Incomplete` / `PageRead`。现有树/全库报告仍沿用 `SqliteError` 状态映射：宿主 `Invalid` 可表现为 `Failed`，详细位置的 `ReadPage` 表示没有取得完整页面，不能据此宣布文件损坏。位置未知时为 `None`；位置指向检查字段或 cell 起点，不保证解码 payload 内部的精确字节地址。

空间分项合计一页。声明 payload 不意味着 overflow 链或内容已验证；对象占页字节包含页头、元数据与空闲区，不是有效数据量。检查未完成时汇总只表示已观察部分；`Complete` 不等同于 SQLite `integrity_check`。

## CLI、JSON 与工具链

旧命令的 JSON 字段保持原有结构；新命令为 `page-inspect`、`tree-inspect`、`inspect-details`、`summary-json`、`viewer-data`，`summary` 输出中文文本。自动消费程序应按命令选择格式。报告命令退出码 `0/1/2` 分别表示完成/失败/未完成；参数及初始化错误写 stderr。

64 位整数、payload 累计值与占页字节仍以十进制字符串输出。详细定位与诊断同步截断，必须读取覆盖标记；界面从 `viewer-data` 的同一次检查报告导航，不能把未认领页一概当作孤儿。

使用 MoonBit release 工具链。发布验收记录 `moon 0.1.20260920`、`moonc 0.10.14`；CI 另使用当次安装的 release 工具链检查四后端。CLI 和模糊测试使用 Node.js 22，完整开发验证使用 Python 3.13。新增纯库 API 无需 Node.js 或 SQLite 引擎；没有新增运行时依赖。离线示例使用完整文件与 Blob Worker，暂不提供异步 `PageSource`。

## 后续 API 演进

0.x 功能版本可以在有明确迁移说明的前提下收紧行为或调整 API；补丁用于保持既定契约的修复。新增字段或枚举分支会影响公开构造和穷举匹配，应先评估独立消费代码。优先新增独立报告、方法或构造入口，再在规划的功能版本中调整旧契约。后续 64 位与异步源将保留当前小文件接口；v1.0 再固定稳定契约。

范围细节见[架构说明](architecture.md)，离线演示见[使用说明](../examples/offline-viewer/README.md)，模糊测试见[重放文档](fuzzing.md)。
