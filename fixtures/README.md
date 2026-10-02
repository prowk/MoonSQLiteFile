# SQLite 测试数据

这些数据库由 `../tools/generate_fixtures.py` 使用 Python 标准库 `sqlite3` 创建。
SQLite 引擎只参与生成独立测试数据；MoonSQLiteFile 库、示例与测试解析器均无需链接 SQLite。

| 文件 | 页大小 | 用途 |
| --- | ---: | --- |
| `core.sqlite` | 512 | 六种样本行、负行号、64 位整数上下界、浮点、NULL、空及非空 BLOB、中文与 emoji、680 行的三层行号 B-tree、长文本与 BLOB overflow、索引、WITHOUT ROWID 表、删除后的 freelist |
| `utf16le.sqlite` | 512 | UTF-16LE 中文、emoji、非 BMP 字符及空字符串 |
| `utf16be.sqlite` | 512 | UTF-16BE 中文、emoji、非 BMP 字符及空字符串 |
| `page65536.sqlite` | 65536 | 文件头页大小特殊编码 `1`、两页真实数据库及文本行 |
| `empty.sqlite` | 512 | 已初始化、无用户表的单页数据库 |

五个二进制文件共 **182,784 字节**。`core.sqlite` 的 `branches` 表包含 680 行，
从根到叶有三层；`overflow_data` 包含 4,000 字节 UTF-8 文本和 2,048 字节 BLOB。
`keyed` 的数据保留在 oracle 中，供验证明确的 WITHOUT ROWID 支持或“不支持”错误行为。

`expected.json` 是 SQLite 实际查询产生的类型化 oracle，记录 SHA-256、页数、编码、
freelist 页数、完整 schema、列名和按行号排序的行。INTEGER 值及行号以十进制字符串保存，
避免 JSON/JavaScript 的精度丢失；BLOB 使用十六进制；TEXT 原样保留；REAL 使用 JSON 数字；
NULL 仅标记类型。REAL 列中的整值仍由 SQLite 查询返回浮点值。

根目录 `fixture_bytes_wbtest.mbt` 自动生成五个 `fixture_<name>() -> Bytes` 函数，
以 512 字节一段的字节字面量嵌入，再按偏移复制为最终数据。
测试不需要文件系统，因此同一组数据库可用于 wasm、JavaScript 和 native 目标。
请修改生成器后重新生成，避免直接修改二进制或嵌入字节代码。

在项目根目录运行：

```powershell
$env:PYTHONUTF8='1'
python tools/generate_fixtures.py
python tools/generate_fixtures.py --check
```

`--check` 会在临时目录重新生成所有数据库、oracle 及 MoonBit 字节代码，并与提交的文件
逐字节比较。生成时检查每个数据库的 `PRAGMA integrity_check`、总文件大小、freelist
以及三层行号树。生成过程没有时间戳或随机输入；初始产物使用 Python 3.13 携带的
SQLite 3.45.3。不同 SQLite 版本可能采用不同页面布局或文件头版本号，导致 `--check`
报告差异；已有文件仍可跨平台解析。
