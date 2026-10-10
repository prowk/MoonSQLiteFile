# Blob/WAL 浏览器检查器

当前源码用于 v0.8.1 开发，尚未发布包；[在线开发演示](https://prowk.github.io/MoonSQLiteFile/) 提供开发预览及 HTML 下载；线上构建可能落后于本地源码，以部署记录为准。已发布 HTML 仍从 [v0.8.0 Release](https://github.com/prowk/MoonSQLiteFile/releases/tag/v0.8.0) 下载；以下命令用于本地构建和使用新版流程。

```sh
moon build --target js --deny-warn
python tools/build_viewer.py
python tools/build_pages.py
python -m http.server 8000 --directory _build/pages
```

打开 http://localhost:8000/。单文件结果为 `_build/moonsqlitefile-viewer.html`，Pages 目录为 `_build/pages`，两者内嵌同一核心、适配层、Worker、界面及示例。下载版字节与单文件构建一致，首页仅增加对应版本下载入口，没有外部运行时依赖。

## 打开、浏览与检查

选择静态 db 及可选同一时刻的 WAL 副本后，只读取文件头和有预算的 schema；WAL 仍须先校验并建立最新已提交覆盖索引。不会自动扫描所有对象树。schema 未完成时明确显示“前缀”，可提高 schema 对象上限后“重新读取对象”；完整结构检查须主动点击按钮。切换主文件清除旧 WAL，关闭旧快照与 Worker，旧响应不覆盖新文件。

对象选择可跳到根页或预览记录；指定页按需读取。完整检查后增加页用途、对象占页、父/子/overflow 关系与诊断位置；归属缺失不推断页用途。页关系索引在报告更新时建立，导航不重复查找全表。布局条、cell 定位与原始字节导航保持。

## 记录预览与导出

预览默认每批 20 条、累计 200 条，每个值显示前 256 字符，最多显示每条记录的前 128 个磁盘字段；界面只保留当前批。继续读取复用原始游标，切换预览根页时停止旧游标。达到数量/payload 预算、取消或错误会保留部分状态，不能当作已读完。更改预算后重新预览。

rowid 单独显示，磁盘整数保留十进制文本，blob 为十六进制。记录值按磁盘存储顺序展示；WITHOUT ROWID 和索引不能解释成 SQL 列顺序，不提供 DDL 列语义还原。界面截断不改变完整 record 解码和单条 payload 上限。

“导出当前报告”输出 schema 或全库检查的 JSON；“导出预览状态”输出游标进度与完成度。格式包含工具版本、范围、实际预算、status/partial 和程序化诊断及位置，不上传到网络。读取失败、预算不足、取消与损坏分别提示重试或定位方式。[错误与报告契约](../../docs/contracts.md)说明兼容与 64 位规则。

预算默认 100000 页/记录、schema 100 对象、64 MiB 累计 payload、120 秒，单条 payload 为 16 MiB。缓存、报告、遍历和 WAL 索引各有独立边界，不承诺恒定内存。异常 WAL 默认拒绝，必要时显式勾选“使用已校验 WAL 前缀”并重新打开；不读取 shm、不加在线锁、不执行 checkpoint。

## Pages 演示

`.github/workflows/pages.yml` 为仅手动运行的部署工作流，指定已审查提交或 tag，完整验收后才上传与部署 `_build/pages`。日常推送只运行 CI 并保存构建目录，不自动上线。Pages 设置使用 GitHub Actions 来源；公开部署须单独授权，开发演示不代表已发布包或 Release。

此前已验收的演示对应源码 `7422bd5`，[固定/latest CI](https://github.com/prowk/MoonSQLiteFile/actions/runs/37925804911) 与[部署工作流](https://github.com/prowk/MoonSQLiteFile/actions/runs/37926485439) 均通过。2026-10-09 使用 Playwright 1.62.1 / Chrome 154 对真实仓库子路径完成示例、静态 db/WAL、页面导航、记录续读、预算、取消、错误、切换与 JSON 导出验收；在线下载与该部署的 CI 产物字节一致。验收中网络仅有站点 GET 请求且无请求体，无外部请求；载入后断网处理通过。

页面从站点加载，数据库仅在本地 File/Blob 中分块读取并由 Worker 处理，不上传数据库。部署后用 `MOONSQLITE_VIEWER_URL` 指向真实仓库子路径，运行同一 `node tools/verify_browser.cjs`，覆盖示例、db/WAL、导航、取消、错误、预览、导出和网络请求边界。

跨平台验收下载内容时，`MOONSQLITE_VIEWER_HTML` 可指向该部署运行的 `github-pages` CI 产物中对应 HTML 文件，仍逐字节比对；默认使用本地构建。基准须从对应成功运行的产物取得，不能用待验收站点的下载自行替代。固定 MoonBit 编译器在 Windows/Linux 可能输出等价但写法不同的指数字面量，不应把另一平台的构建字节当作该部署产物。

## 验收与启动边界

完整验收使用 `python tools/verify.py`。单项反馈先构建 Pages 目录，执行 `python tools/generate_browser_fixtures.py` 后运行 `node tools/verify_browser.cjs`；准备固定 Playwright/Chromium 的方式见[贡献指南](../../CONTRIBUTING.md)。结果与截图在 `_build/browser-acceptance.json`、`_build/browser-acceptance/viewer-large.png`。

支持 HTTP 载入后断网处理；直接 file:// 双击仍未验收，也不承诺关闭浏览器后离线重启。完整边界集中在[支持说明](../../docs/support.md#浏览器启动方式)。
