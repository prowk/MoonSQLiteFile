# 工具链与宿主支持

固定验收配置在 `tools/toolchain.json`：MoonBit 官方安装版本 `0.10.14+7d59c7ec9`，moon `0.1.20260920`（914d7da）、moonc `v0.10.14+7d59c7ec9`、moonrun `0.1.20260920`，Node 22.14.0、Python 3.13.2、Playwright 1.62.1。Python/SQLite 和 Playwright 只用于开发验收，不是核心或异步包运行依赖。

CI 使用独立的 pinned 与 latest MoonBit 通道，完整运行相同检查。2026-10-06 核对官方 Windows latest：16 个二进制 checksum 和 1043 个标准库源码文件与本机固定版本一致；这是同一当前 release 的验收，未编造两个不同版本。latest 将来变化时，独立 CI 才证明新版本是否仍兼容，不能把今天的结果用于任意未来 release。

| 层 | 有实测的范围 | 约束 |
| --- | --- | --- |
| 核心与供页游标 | Windows x64 与 Linux x64 的 Wasm、WasmGC、JS、native | 无宿主 I/O，仅标准库；其他系统/架构未宣称已验证 |
| 同步文件 CLI | Node 22.14.0 | 只读静态文件；BigInt 范围定位、读取时变化检测，不获取在线锁 |
| 独立异步包 | Node 22.14.0，Chrome/Chromium 的 Blob/Worker | 私有本地包和发布附件，尚未 npm 发布；第三方源须管理自身在途 I/O |
| 浏览器查看器 | Chrome 154 与 CI 固定 Playwright 所装 Chromium | 实际选文件、WAL、导航、取消、切换与 HTTP 载入后断网；直接 file:// 不宣称通过 |
| Python oracle | Python 3.13.2 / SQLite 版本写入日志 | Linux 必须支持 dbstat；本机不支持时明确记录，不将它当 Linux 页统计证据 |

固定版本安装使用 MoonBit [官方版本参数](https://www.moonbitlang.com/updates/page/5)：

```sh
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash -s '0.10.14+7d59c7ec9'
```

Windows 使用官方安装器的 `MOONBIT_INSTALL_VERSION` 参数；已有工作环境运行 `python tools/verify_toolchain.py` 核对，而非覆盖用户的全局安装。完整版本、平台和 SQLite 环境保存在 `_build/toolchain-pinned.json` 与 `_build/toolchain-latest.json`。

Node 范围源须提供不可变配对 db/WAL 副本；64 位寻址不等于常量内存。旧 PageSource 有 Int 限制，页号仍最多 2147483647；单条记录、路径、全局报告与 WAL 覆盖索引分别受预算约束。任意同步 visitor 或单次核心调用不能被 AbortSignal 强制抢占。
