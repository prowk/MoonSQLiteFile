# 离线页面检查器

执行 `moon build --target js cmd/inspect`，然后运行 `python tools/build_viewer.py`，得到 `_build/moonsqlitefile-viewer.html`。GitHub Release 同时提供构建好的 HTML；将它保存到本地，在支持 Blob Worker 的现代浏览器中打开。无需安装服务器或依赖网络资源。

选择完整的静态 SQLite 文件副本，或点击“载入示例库”。对象选择器跳转到根页，页面关系按钮跳转到父页、子页或 overflow 页；页号和前后页按钮可查看其他页面。B-tree 页面显示空间统计和 cell 位置，所有页面都可分段查看原始字节。诊断按钮跳到已知失败页和页内偏移。

解析由编译后的 MoonBit CLI 在 Worker 中执行，界面复用 `viewer-data`、`page-inspect` 报告。文件内容保存在本页面，CSP 禁止网络请求。演示完整读取文件，限制为 64 MiB，每次检查最多运行 30 秒；切换文件或页面会取消旧检查。限额、超时或错误不会被展示为成功。

统计描述已观察到的归属。未完成检查可能缺少对象或页面；页面空间报告不验证 overflow 链和 record 内容。全库检查不验证 SQL 排序或表/索引内容一致性，不等同于 SQLite `integrity_check`。不支持 WAL、实时数据库读取或损坏数据恢复。大文件和批量检查请使用 CLI。
