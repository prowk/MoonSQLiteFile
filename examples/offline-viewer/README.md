# 单文件 Blob/WAL 检查器

可从 [v0.8.0 Release](https://github.com/prowk/MoonSQLiteFile/releases/tag/v0.8.0) 下载 HTML，或从源码构建：

```sh
moon build --target js --deny-warn
python tools/build_viewer.py
```

结果为 `_build/moonsqlitefile-viewer.html`，包含同一 MoonBit 核心、异步适配层、Worker、界面及示例库，没有外部资源。格式解析和完整检查仍在核心执行，主线程只展示报告和当前页字节。

选择静态数据库副本后自动检查；可再选择来自同一时刻的 WAL，重新打开最新已提交快照。切换主文件会清除旧 WAL。异常 WAL 默认拒绝，需要时在“检查预算”中显式选择“使用已校验 WAL 前缀”，点击“重新检查”。应用不读取 shm、不加在线锁、不执行 checkpoint。

“检查预算”可以调整最多页、记录、累计 payload 和最长秒数。默认 100000 页/记录、64 MiB 累计 payload、120 秒，单条 payload 为 16 MiB。没有原来的 64 MiB 文件长度硬限制。取消或预算耗尽保留部分全库报告及诊断；初始文件头或 WAL 打开失败时没有可用数据库。文件切换时关闭旧快照并终止旧 Worker，旧响应不覆盖新文件。

概览展示覆盖状态、页用途与对象占页；对象选择跳到根页，关系按钮跳到父/子/overflow 页。页内空间条、cell 下拉框及原始字节导航保持。导航通过已打开的快照按页读取，不重新全库扫描。归属未完成时不根据未认领页推断用途。

使用本机 HTTP 启动；实际支持方式和直接 file:// 的验收边界见[支持说明](../../docs/support.md#浏览器启动方式)。历史大库结果见[v0.8.0 验证记录](../../docs/validation-v0.8.0.md)。当前源码构建为未发布的 v0.8.2，下载附件仍为 v0.8.0。

复现：先执行 `python tools/generate_browser_fixtures.py`，安装 CI 固定的 Playwright 1.62.1 / Chromium，再运行 `node tools/verify_browser.cjs`。也可以用 `MOONSQLITE_PLAYWRIGHT` 指定已有 Playwright 的绝对路径、`MOONSQLITE_BROWSER` 指定 Chrome 可执行文件。结果及截图保存在 `_build/browser-acceptance.json`、`_build/browser-acceptance/viewer-large.png`。

`node tools/verify_viewer.cjs` 单独验证实际 HTML 内嵌代码的无外部依赖、导航数据、报告及释放。生命周期见[异步范围读取](../../docs/async-source.md)，历史变更见[升级说明](../../docs/migration.md)。
