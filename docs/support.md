# 工具链与宿主支持

固定验收配置在 `tools/toolchain.json`：MoonBit 官方安装版本 `0.10.14+7d59c7ec9`，moon `0.1.20260920`（914d7da）、moonc `v0.10.14+7d59c7ec9`、moonrun `0.1.20260920`，Node 22.14.0、Python 3.13.2、Playwright 1.62.1。Python/SQLite 和 Playwright 只用于开发验收，不是核心或异步包运行依赖。

CI 的 pinned 与 latest MoonBit 通道完整运行同一入口；固定配置不等于任意未来 latest 都兼容。历史环境核对见[v0.8.0 验证记录](validation-v0.8.0.md)。环境准备和运行方式见[贡献指南](../CONTRIBUTING.md#环境准备)。

| 层 | 有实测的范围 | 约束 |
| --- | --- | --- |
| 核心与供页游标 | Windows x64 与 Linux x64 的 Wasm、WasmGC、JS、native | 无宿主 I/O，仅标准库；其他系统/架构未宣称已验证 |
| 同步文件 CLI | Node 22.14.0 | 只读静态文件；BigInt 范围定位、读取时变化检测，不获取在线锁 |
| 独立异步包 | Node 22.14.0，Chrome/Chromium 的 Blob/Worker | 离线 tarball 和发布附件，尚未 npm 发布；第三方源须管理自身在途 I/O |
| 浏览器查看器 | Chrome 154 与 CI 固定 Playwright 所装 Chromium | 实际选文件、WAL、导航、取消、切换与 HTTP 载入后断网；直接 file:// 不宣称通过 |
| Python oracle | Python 3.13.2 / SQLite 版本写入日志 | Linux 必须支持 dbstat；本机不支持时明确记录，不将它当 Linux 页统计证据 |

固定版本安装使用 MoonBit [官方版本参数](https://www.moonbitlang.com/updates/page/5)：

```sh
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash -s '0.10.14+7d59c7ec9'
```

Windows 使用官方安装器的 `MOONBIT_INSTALL_VERSION` 参数；已有工作环境运行 `python tools/verify_toolchain.py` 核对，而非覆盖用户的全局安装。完整版本、平台和 SQLite 环境保存在 `_build/toolchain-pinned.json` 与 `_build/toolchain-latest.json`。

Node 范围源须提供不可变配对 db/WAL 副本；64 位寻址不等于常量内存。旧 PageSource 有 Int 限制，页号仍最多 2147483647；单条记录、路径、全局报告与 WAL 覆盖索引分别受预算约束。任意同步 visitor 或单次核心调用不能被 AbortSignal 强制抢占。

## 总体支持与限制

- 支持 SQLite 3 普通 rowid 表、多层 table B-tree、schema、overflow、freelist、UTF-8/UTF-16LE/UTF-16BE、512–65536 字节页。
- 四种 B-tree 均可遍历记录；索引采用左子树 → 内部 cell → 右子树顺序。WITHOUT ROWID 返回主键列在前的磁盘存储顺序，rowid 为 None。索引返回索引字段与附加 rowid/主键；附加值保留在 values 中，不单独推断。
- `read_table`/`table_rows` 保持 v0.1 的普通 rowid 表接口；WITHOUT ROWID 请使用 `table_records`。尚不解释 SQL 列映射、collation、DESC 排序或约束，不对这些语义宣称验证通过。
- 提供 WAL 帧校验和最新已提交只读覆盖源；默认拒绝无效尾部，显式前缀策略只采用此前完整提交。只读快照不写回主文件。
- 不执行 SQL、不写入数据库、不执行 checkpoint、不处理 hot rollback journal、不恢复删除记录、不解密文件。
- 输入须为未被其他进程写入的完整静态副本。WAL 模式可先 checkpoint/备份后读取主文件，或提供同一时刻的一致 db/WAL 副本并显式使用 WAL 入口；只读取 `.db` 无法看到未 checkpoint 的事务。salt/checksum 不验证主文件身份，在线锁协议仍由宿主提供。

`Complete` 仅表示声明范围内结构检查完成，不等同于 SQLite `integrity_check`。默认页、记录、单条及累计 payload 等预算和 CLI 行为见[使用指南](usage.md#资源选项与输出)。64 位寻址及缓存不会使 payload、路径、归属报告或 WAL 索引成为常量内存；详见[范围源预算](range-source.md#缓存索引和报告预算)。

## 浏览器启动方式

发布 HTML 可通过本机 HTTP 使用，例如从文件所在目录运行 `python -m http.server 8000` 后打开对应文件 URL。已验收 HTTP 载入后断网的 File/Blob/Worker 场景；关闭浏览器后离线重新打开不是同一能力。直接 `file://` 双击仍未验收，不承诺无需服务器；其他浏览器未声明通过。操作和构建见[查看器说明](../examples/offline-viewer/README.md)，历史规模与截图记录见[v0.8.0 验证记录](validation-v0.8.0.md)。

当前开发源码的浏览器流程先读取有界 schema，再由用户选择预览或完整检查；[在线开发演示](https://prowk.github.io/MoonSQLiteFile/) 与 HTML 下载版复用核心及 Worker，由获授权的手动工作流部署。[查看器说明](../examples/offline-viewer/README.md#pages-演示)记录部署与真实站点验收证据。分发仍以本地 tarball/已发布 v0.8.0 附件为准，npm registry 未发布。错误与完成度规则见[错误与报告契约](contracts.md)。

## 当前规模验收

2026-10-10 Windows x64 / Node 22.14.0 的独立进程实测如下；默认仍受各项独立预算限制。进程峰值使用操作系统 maxRSS，含运行时和报告开销，不能推广为常量内存或其他环境的性能保证。

| 静态样本 | 结果 | Node 进程峰值约数 |
| --- | --- | --- |
| 128 MiB payload、32804 页 | 默认 64 MiB 累计预算未完成；提高到 160 MiB 后完整检查 17 条（含 schema） | 161 / 211 MiB |
| 120000 条小记录、133 个 schema 对象 | 默认全局记录 100000 停止；max_rows=200000 后完整检查 120133 条 | 71 / 75 MiB |
| 99993 帧 WAL | 默认完整校验并读取最新计数 99990；99000 帧预算明确拒绝；中途取消释放配对源 | 436 MiB |

所有实际单次文件读取不超过 4096 字节。schema 上限 100 时返回前缀，提高到 200 时读全 133 对象。取消后完成等待约 0.6–1 ms（不包括计时器调度前等待）；这不承诺同步核心或业务回调可被强制抢占。

Playwright 1.62.1 / Chrome 154 的 8×4 MiB BLOB 展示基线传送约 64 MiB 字符；当前按大值门槛暂停并截短，首批 1 条的消息约 1.6 KiB，继续读取不丢游标。独立浏览器的各进程 RSS 高水位之和从基线约 1543 MiB 降至两批后的约 884–951 MiB，含浏览器固定开销且各进程峰值不保证同时发生；单条完整解码仍可产生较大瞬时内存。150 字段宽记录的首批展示止于 262144 字符，库扫描仍返回完整 150 字段。128 MiB 检查的界面取消等待约 46–51 ms，记录预览取消约 27 ms；这些时间只表示已观测的操作，不代表同步核心调用可被抢占。预览中更换 db 或配对 WAL 后，旧 Worker 的核心句柄清零且新操作仍可继续。

持续复现入口仍是完整验收；原始数据保存在 CI 的 scale-acceptance/browser-scale-acceptance 产物中，包含平台、实际 I/O、时间、内存口径和关闭句柄，不用旧版本日志替代当前运行。
