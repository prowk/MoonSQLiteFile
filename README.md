# MoonSQLiteFile

纯 MoonBit 实现的 SQLite 3 数据库文件解析与检查库。直接读取磁盘格式，不调用 SQLite 引擎，不提供 SQL 执行或数据库写入。

首个版本目标：数据库头 → B-tree 页面 → 记录 → sqlite_schema → 普通 rowid 表 → CLI 检查器。

规范依据：[SQLite Database File Format](https://sqlite.org/fileformat.html)。

## 开发

```sh
moon check
moon test
```
