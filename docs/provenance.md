# 实现来源与开发说明

本项目依据 [SQLite 官方磁盘格式规范](https://sqlite.org/fileformat.html) 和 [schema table 定义](https://sqlite.org/schematab.html) 独立实现，未复制第三方 SQLite 解析器或移植 SQLite C 引擎。官方规范规定字段偏移、页面类型、varint、serial type 和 payload 分配公式，代码结构与 API 由本项目设计。

核心实现使用 MoonBit 标准库的 UTF-8/UTF-16 解码器和字节 buffer。Node 标准库仅作为 CLI 的文件输入与进程输出适配器。Python 标准库 sqlite3 生成测试样本和 oracle；SQLite 引擎不属于库或 CLI 的运行时依赖。

开发使用 Codex AI 及子 Agent 辅助实现、规则核实和代码审查。测试覆盖确定样本、随机真实数据库、损坏输入与跨后端运行；这些工程验证不能替代参赛者对核心代码的理解。正式比赛申报书按章程由参赛者本人撰写。

项目采用 Apache-2.0，完整文本见 LICENSE。生成测试数据库只包含本项目构造的示例数据，没有真实用户数据。
