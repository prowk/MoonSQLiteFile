# 2026 年十月 MoonBit 黑客松：工程准备记录

核实日期：2026-10-02（Asia/Shanghai）。本文记录工程要求和选题调查，不是已提交的项目申报书，也不代表报名、验收或发布已经成功。

## 官方来源与日期差异

- [十月赛事官网](https://moonbitlang.github.io/Hackathon2026/)及其[官方源码](https://github.com/moonbitlang/Hackathon2026/blob/main/src/App.tsx)明确写明：报名与验收截止日期为 **2026-10-31**，十月沿用表单且最多提交 3 次，团队人数不超过 3 人。
- [正式赛事章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)在本次读取时仍有 9 月 30 日的旧赛程段落。提交前须再核对赛事群最新通知；本项目按十月官网的 10 月 31 日规划，不把旧月份机械用于本期。
- [官网报名表](https://bxup9uklfcb.feishu.cn/share/base/form/shrcnWUMlgpbwHaXgzV7HmNhNhg)和[赛事交流群](https://work.weixin.qq.com/gm/5b6b92c8677d0555f3fb6a3f1a081399)由参赛者本人完成。官方要求加入交流群并将昵称设置为 GitHub ID。

## 交付要求

正式章程要求 MoonBit 作为主要实现语言、公开 GitHub 仓库、清晰结构与核心功能、README 中可复现的安装和用法、运行样例、覆盖核心路径的测试、检查/构建/测试的持续集成、OSI 许可证及来源披露，以及发布到 mooncakes.io。有效提交不得靠空提交、机械拆分或重复内容凑数；首次工程开发与后续维护都应有可追踪的真实改进。[依据：正式赛事章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)。

章程明确要求至少 10 个有效 commits。本项目按独立工程成果组织提交，例如文件头解析、变长整数、记录解码、页面检查、B-tree 遍历、溢出页、schema、表扫描、真实 SQLite 样本验证、CLI、CI 和文档；提交是否有效由赛事方最终评定。

申报书应由参赛者人工撰写，控制在一页 Markdown，说明价值、技术路径、交付边界及至少 3 个完整使用场景。README 和本文件可作为理解项目的工程资料，不能替代这一人工撰写要求。[依据：正式赛事章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)。

本次已读取的规则未发现禁止普通第三方依赖或固定代码行数门槛；这不构成对未读取或后续更新规则的保证。AI 辅助允许，但参赛者须理解核心实现并承担工程质量与开源合规责任。[依据：官网验收标准](https://github.com/moonbitlang/Hackathon2026/blob/main/src/App.tsx)。

## SQLite 生态调查与本项目价值

2026-10-02 查阅 mooncakes.io 中的公开文档：

| 已有项目 | 公开定位 | MoonSQLiteFile 的不同用途 |
| --- | --- | --- |
| [moonbit-community/sqlite3](https://mooncakes.io/docs/moonbit-community/sqlite3) | SQLite C API 绑定；native 使用 SQLite 源码，wasm 使用宿主 SQLite 导入 | 直接解码数据库字节并暴露页面结构，不加载 SQLite 引擎 |
| [mizchi/sqlite](https://mooncakes.io/docs/mizchi/sqlite) | native C FFI 与 Node.js SQLite 绑定，提供 SQL 执行与事务 | 只读检查文件格式、记录和损坏位置，纯 MoonBit 核心可跨后端 |
| [Lfan-ke/moon-sqlite](https://mooncakes.io/docs/Lfan-ke/moon-sqlite) | 基于 native FFI 的 moondb/moonorm SQLite 驱动 | 作为二进制格式解析库使用，不充当 ORM 或连接驱动 |

调查未找到与“纯 MoonBit SQLite 文件结构解析器”同定位的成熟包；搜索结果不能证明整个生态不存在相似实现。投稿前应再查 mooncakes.io，说明上述差异，由赛事方判断是否满足新增生态价值要求。

技术规范参考 [SQLite Database File Format](https://sqlite.org/fileformat.html)，采用独立实现。首版聚焦数据库头、rowid 表 B-tree、SQLite 记录、溢出页、sqlite_schema 与只读检查器；SQL 引擎、写入、WAL 合并和完整取证恢复属于后续或范围外能力。

## 当前记录与待办

已完成本次规则来源核实、日期冲突记录与 SQLite 生态初步比较。实际代码能力与本地验证结果以 README、测试输出和 Git 历史为准。

- [ ] 核对 GitHub 公开仓库、有效提交数量和远端 CI 结果。
- [ ] 确认示例、核心测试、许可证和安装说明齐全。
- [ ] 注册并发布 mooncakes.io 包，保留发布版本与链接。
- [ ] 参赛者亲自完成一页项目申报书，并加入赛事群。
- [ ] 提交报名表及最终验收材料，记录官方确认结果。

上述未勾选事项是待办清单，不表示已经报名、发布或验收通过。
